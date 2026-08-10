// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    VRFCoordinatorV2_5Mock
} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Lottery} from "../src/Lottery.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @dev 不变量测试 Handler：有界随机调用（FR-T-03）。
///      跟踪四个 ghost 量：总购票额、总注资额、总派奖额、总提费额
contract LotteryHandler is Test {
    Lottery public immutable lottery;
    VRFCoordinatorV2_5Mock public immutable coordinator;
    MockERC20 public immutable token;
    address public immutable treasury;

    address[3] public actors;
    uint256 public totalBought;
    uint256 public totalInjected;
    uint256 public totalPrizesPaid;
    uint256 public totalFeesWithdrawn;

    constructor(
        Lottery lottery_,
        VRFCoordinatorV2_5Mock coordinator_,
        MockERC20 token_,
        address treasury_
    ) {
        lottery = lottery_;
        coordinator = coordinator_;
        token = token_;
        treasury = treasury_;
        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");
    }

    function buy(uint256 actorSeed, uint32 qty) external {
        qty = uint32(bound(qty, 1, 200));
        address actor = actors[bound(actorSeed, 0, 2)];
        uint32 cur = lottery.s_currentRound();
        (Lottery.RoundState st, uint64 closeTime,,,,,,,) = lottery.getRound(cur);
        if (
            st != Lottery.RoundState.OPEN || block.timestamp >= closeTime || lottery.s_salesPaused()
        ) {
            return;
        }
        uint256 cost = uint256(qty) * 1e6;
        token.mint(actor, cost);
        vm.startPrank(actor);
        token.approve(address(lottery), cost);
        lottery.buyTickets(qty);
        vm.stopPrank();
        totalBought += cost;
    }

    function inject(uint256 amount) external {
        amount = bound(amount, 1, 500e6);
        uint32 cur = lottery.s_currentRound();
        (Lottery.RoundState st,,,,,,,,) = lottery.getRound(cur);
        if (st != Lottery.RoundState.OPEN) return;
        token.mint(address(this), amount);
        token.approve(address(lottery), amount);
        lottery.injectPot(cur, amount);
        totalInjected += amount;
    }

    function skipTime(uint256 secs) external {
        secs = bound(secs, 1 hours, 5 days);
        vm.warp(block.timestamp + secs);
    }

    function drawAndFulfill(uint256 seed) external {
        uint32 cur = lottery.s_currentRound();
        (Lottery.RoundState st,, uint64 drawTime,,,,,,) = lottery.getRound(cur);
        if (st != Lottery.RoundState.OPEN) return;
        if (block.timestamp < drawTime) {
            vm.warp(drawTime);
        }
        lottery.performUpkeep("");
        (uint256 requestId,) = lottery.vrfRequestOf(cur);
        if (requestId != 0) {
            uint256[] memory words = new uint256[](1);
            words[0] = seed;
            coordinator.fulfillRandomWordsWithOverride(requestId, address(lottery), words);
        }
    }

    function claim(uint256 actorSeed, uint256 roundSeed, uint8 tier) external {
        uint32 cur = lottery.s_currentRound();
        uint32 roundId = uint32(bound(roundSeed, 1, cur));
        tier = uint8(bound(tier, 0, 2));
        address actor = actors[bound(actorSeed, 0, 2)];
        uint256 before = token.balanceOf(actor);
        vm.prank(actor);
        try lottery.claim(roundId, tier) {
            totalPrizesPaid += token.balanceOf(actor) - before;
        } catch {}
    }

    function rolloverExpired(uint256 roundSeed) external {
        uint32 cur = lottery.s_currentRound();
        uint32 roundId = uint32(bound(roundSeed, 1, cur));
        try lottery.rolloverExpired(roundId) {} catch {}
    }

    function withdrawFees() external {
        uint256 before = token.balanceOf(treasury);
        try lottery.withdrawFees() {
            totalFeesWithdrawn += token.balanceOf(treasury) - before;
        } catch {}
    }

    /// @dev 覆盖暂停快照路径（审计第三轮 #1）：owner 任意时刻切换，
    ///      不变量必须在「有期被禁售、有期正常」的混合状态下依然成立
    function togglePause(bool paused) external {
        vm.prank(lottery.owner());
        try lottery.setSalesPaused(paused) {} catch {}
    }

    /// @dev 覆盖 VRF 重试路径（审计第二轮 B）：超时后追加请求，
    ///      两个 requestId 同时挂起时先到先得，不得造成重复结算或资金错乱
    function retryDraw(uint256 roundSeed) external {
        uint32 cur = lottery.s_currentRound();
        uint32 roundId = uint32(bound(roundSeed, 1, cur));
        try lottery.retryDraw(roundId) {} catch {}
    }

    /// @dev 覆盖「旧请求迟到回调」：对任意期用任意 requestId 尝试回调，
    ///      验证 state 闸在乱序下的稳健性
    function lateFulfill(uint256 roundSeed, uint256 seed) external {
        uint32 cur = lottery.s_currentRound();
        uint32 roundId = uint32(bound(roundSeed, 1, cur));
        (uint256 requestId,) = lottery.vrfRequestOf(roundId);
        if (requestId == 0) return;
        uint256[] memory words = new uint256[](1);
        words[0] = seed;
        try coordinator.fulfillRandomWordsWithOverride(requestId, address(lottery), words) {}
            catch {}
    }
}

contract LotteryInvariantTest is Test {
    uint64 internal constant ANCHOR = 1_700_000_000;

    Lottery internal lottery;
    VRFCoordinatorV2_5Mock internal coordinator;
    MockERC20 internal token;
    LotteryHandler internal handler;
    address internal treasury = makeAddr("treasury");

    uint8[3] internal WINNER_COUNTS = [1, 2, 5];

    function setUp() public {
        vm.warp(ANCHOR + 1);
        coordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        uint256 subId = coordinator.createSubscription();
        coordinator.fundSubscription(subId, 100_000 ether);
        token = new MockERC20("Mock USDC", "USDC", 6);

        uint32[] memory intervals = new uint32[](3);
        intervals[0] = 2 days;
        intervals[1] = 3 days;
        intervals[2] = 2 days;
        uint16[] memory tierBps = new uint16[](3);
        tierBps[0] = 6000;
        tierBps[1] = 2500;
        tierBps[2] = 1500;
        uint8[] memory tierWinners = new uint8[](3);
        tierWinners[0] = 1;
        tierWinners[1] = 2;
        tierWinners[2] = 5;

        lottery = new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            address(token),
            1e6,
            ANCHOR,
            intervals,
            treasury,
            100,
            tierBps,
            tierWinners
        );
        coordinator.addConsumer(subId, address(lottery));

        handler = new LotteryHandler(lottery, coordinator, token, treasury);
        targetContract(address(handler));
    }

    /// @dev 某期未领奖金合计（已结算期）
    function _unclaimedOf(uint32 roundId) internal view returns (uint256 unclaimed) {
        (Lottery.RoundState st,,,,,,, uint16 claimedBits,) = lottery.getRound(roundId);
        if (st != Lottery.RoundState.SETTLED) return 0;
        uint8 slot = 0;
        for (uint8 tier = 0; tier < 3; tier++) {
            uint256 perWinner = lottery.perWinnerAmount(roundId, tier);
            for (uint8 j = 0; j < WINNER_COUNTS[tier]; j++) {
                if (perWinner > 0 && claimedBits & (uint16(1) << slot) == 0) {
                    unclaimed += perWinner;
                }
                slot++;
            }
        }
    }

    /// @dev FR-T-03 不变量一：合约余额 >= 所有未领奖金 + accruedFees（此处收紧为恒等式）
    function invariant_SolvencyExact() public view {
        // 滚存缓冲区（修复 A）也是待并入下一新期的应付义务
        uint256 obligations =
            lottery.s_accruedFees() + lottery.s_pendingPot() + lottery.s_pendingTier1();
        uint32 cur = lottery.s_currentRound();
        for (uint32 id = 1; id <= cur; id++) {
            (Lottery.RoundState st,,,, uint256 pot, uint256 carry,,,) = lottery.getRound(id);
            if (st == Lottery.RoundState.OPEN || st == Lottery.RoundState.DRAWING) {
                obligations += pot + carry;
            } else if (st == Lottery.RoundState.SETTLED) {
                obligations += _unclaimedOf(id);
            }
            // VOIDED 期的资金已全额转移到下期，贡献为 0
        }
        uint256 balance = token.balanceOf(address(lottery));
        assertGe(balance, obligations, "solvency violated");
        assertEq(balance, obligations, "accounting leak detected");
    }

    /// @dev FR-T-03 不变量二：资金守恒——流入 == 在库 + 流出
    function invariant_Conservation() public view {
        assertEq(
            handler.totalBought() + handler.totalInjected(),
            token.balanceOf(address(lottery)) + handler.totalPrizesPaid()
                + handler.totalFeesWithdrawn(),
            "conservation violated"
        );
    }

    /// @dev 附加不变量：抽成永不超过历史购票额的 MAX_FEE_BPS
    function invariant_FeesNeverExceedCap() public view {
        uint256 feesEver = lottery.s_accruedFees() + handler.totalFeesWithdrawn();
        assertLe(
            feesEver, (handler.totalBought() * lottery.MAX_FEE_BPS()) / 10000, "fees exceed cap"
        );
    }
}
