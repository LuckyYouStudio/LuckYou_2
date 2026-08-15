// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    VRFCoordinatorV2_5Mock
} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Lottery} from "../src/Lottery.sol";

/// @dev 不变量测试 Handler：有界随机调用（FR-T-03）。
///      跟踪四个 ghost 量：总购票额、总注资额、总派奖额、总提费额
contract LotteryHandler is Test {
    Lottery public immutable lottery;
    VRFCoordinatorV2_5Mock public immutable coordinator;
    address public immutable treasury;
    uint256 public immutable subId;

    address[3] public actors;
    uint256 public totalBought;
    uint256 public totalInjected;
    uint256 public totalPrizesPaid;
    uint256 public totalFeesWithdrawn;
    uint256 public totalRefunded;
    uint256 public totalKeeperPaid;
    uint256 public abandonOk;
    uint256 public abandonTried;
    uint32[] internal drawingRounds;

    constructor(
        Lottery lottery_,
        VRFCoordinatorV2_5Mock coordinator_,
        address treasury_,
        uint256 subId_
    ) {
        lottery = lottery_;
        coordinator = coordinator_;
        treasury = treasury_;
        subId = subId_;
        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");
    }

    function buy(uint256 actorSeed, uint32 qty) external {
        qty = uint32(bound(qty, 1, 200));
        address actor = actors[bound(actorSeed, 0, 2)];
        uint32 cur = lottery.s_currentRound();
        (Lottery.RoundState st, uint64 closeTime,,,,,,,) = lottery.getRound(cur);
        // 用 salesOpenFor（开期快照）而非全局 s_salesPaused——后者在快照语义下是错的闸，
        // 会让 handler 在当期本可购票时也跳过（第十轮红队 #6）
        if (
            st != Lottery.RoundState.OPEN || block.timestamp >= closeTime
                || !lottery.salesOpenFor(cur)
        ) {
            return;
        }
        uint256 cost = uint256(qty) * 1e14;
        vm.deal(actor, actor.balance + (cost));
        uint32 _rid1 = lottery.s_currentRound();
        vm.startPrank(actor);
        lottery.buyTickets{value: cost}(qty, _rid1);
        vm.stopPrank();
        totalBought += cost;
    }

    function inject(uint256 amount) external {
        amount = bound(amount, 1, 500e14);
        uint32 cur = lottery.s_currentRound();
        (Lottery.RoundState st, uint64 closeTime,,,,,,,) = lottery.getRound(cur);
        if (st != Lottery.RoundState.OPEN || block.timestamp >= closeTime) return;
        vm.deal(address(this), address(this).balance + (amount));
        lottery.injectPot{value: amount}(cur);
        totalInjected += amount;
    }

    receive() external payable {}

    function skipTime(uint256 secs) external {
        secs = bound(secs, 1 hours, 5 days);
        vm.warp(block.timestamp + secs);
    }

    /// @dev 只触发开奖，**不**立即履约——否则不会有任何期停留在 DRAWING，
    ///      retryDraw / fulfillPending 两条路径就永远是死代码（第十轮红队 #6）
    function draw() external {
        uint32 cur = lottery.s_currentRound();
        (Lottery.RoundState st,, uint64 drawTime,,,,,,) = lottery.getRound(cur);
        if (st != Lottery.RoundState.OPEN) return;
        if (block.timestamp < drawTime) {
            vm.warp(drawTime);
        }
        lottery.performUpkeep("");
        // 零购票期会被直接 VOID，不该记进「待履约」列表——否则 fulfillPending 与
        // abandon 会把配额浪费在永远不可能命中的期上
        (Lottery.RoundState after_,,,,,,,,) = lottery.getRound(cur);
        if (after_ == Lottery.RoundState.DRAWING && drawingRounds.length < 32) {
            drawingRounds.push(cur);
        }
    }

    /// @dev 履约某个仍在 DRAWING 的期（可乱序，覆盖多请求并存的记账）
    function fulfillPending(uint256 pick, uint256 seed) external {
        if (drawingRounds.length == 0) return;
        uint256 i = bound(pick, 0, drawingRounds.length - 1);
        uint32 roundId = drawingRounds[i];
        (uint256 requestId,) = lottery.vrfRequestOf(roundId);
        if (requestId == 0) return;
        uint256[] memory words = new uint256[](1);
        words[0] = seed;
        try coordinator.fulfillRandomWordsWithOverride(requestId, address(lottery), words) {}
            catch {}
    }

    function claim(uint256 actorSeed, uint256 roundSeed, uint8 tier) external {
        uint32 cur = lottery.s_currentRound();
        uint32 roundId = uint32(bound(roundSeed, 1, cur));
        tier = uint8(bound(tier, 0, 2));
        address actor = actors[bound(actorSeed, 0, 2)];
        uint256 before = actor.balance;
        vm.prank(actor);
        try lottery.claim(roundId, tier) {
            totalPrizesPaid += actor.balance - before;
        } catch {}
    }

    function rolloverExpired(uint256 roundSeed) external {
        uint32 cur = lottery.s_currentRound();
        uint32 roundId = uint32(bound(roundSeed, 1, cur));
        try lottery.rolloverExpired(roundId) {} catch {}
    }

    function withdrawFees() external {
        uint256 before = treasury.balance;
        try lottery.withdrawFees() {
            totalFeesWithdrawn += treasury.balance - before;
        } catch {}
    }

    /// @dev 覆盖暂停快照路径（审计第三轮 #1）：owner 任意时刻切换，
    ///      不变量必须在「有期被禁售、有期正常」的混合状态下依然成立
    function togglePause(bool paused) external {
        vm.prank(lottery.owner());
        try lottery.setSalesPaused(paused) {} catch {}
    }

    /// @dev 确定性地造一个「真的卡死」的期，供 FR-C-29 的逃生通道使用。
    ///
    ///      为什么必须是组合动作：靠随机 handler 自然凑出「买票 → VRF 故障 → 开奖 →
    ///      过 30 天 → 作废 → 退款」这 6 步有序动作，在 fuzz 里概率低到不可达。
    ///      实测探针数据：单独的 abandon/refund handler 跑完整轮后成功次数**恒为 0**，
    ///      也就是说 ABANDONED 状态的记账从未被守恒检查覆盖过——
    ///      而那正是一个**持有资金**的新状态，不覆盖等于白加。
    ///      关键在于开奖那一刻 VRF 必须是坏的：否则 fulfillPending 会把它结算掉，
    ///      期就不再是 DRAWING，也就永远等不到可作废的时刻
    function createStuckRound(uint32 qty) external {
        uint32 cur = lottery.s_currentRound();
        (Lottery.RoundState st, uint64 closeTime, uint64 drawTime,,,,,,) = lottery.getRound(cur);
        if (
            st != Lottery.RoundState.OPEN || block.timestamp >= closeTime
                || !lottery.salesOpenFor(cur)
        ) {
            return;
        }
        qty = uint32(bound(qty, 1, 50));
        uint256 cost = uint256(qty) * 1e14;
        address actor = actors[0];
        vm.deal(actor, actor.balance + cost);
        uint32 _rid2 = lottery.s_currentRound();
        vm.prank(actor);
        lottery.buyTickets{value: cost}(qty, _rid2);
        totalBought += cost;

        // 让 VRF 请求失败 → 该期停在 DRAWING 且 requestId 为 0，fulfillPending 救不了它
        try coordinator.removeConsumer(subId, address(lottery)) {} catch {}
        vm.warp(drawTime);
        lottery.performUpkeep("");
        try coordinator.addConsumer(subId, address(lottery)) {} catch {}

        (Lottery.RoundState after_,,,,,,,,) = lottery.getRound(cur);
        if (after_ == Lottery.RoundState.DRAWING && drawingRounds.length < 32) {
            drawingRounds.push(cur);
        }
    }

    /// @dev 领取 FR-C-30 的开奖奖励。handler 自己就是 performUpkeep 的调用者，
    ///      所以奖励会记在 handler 名下
    function claimKeeperReward() external {
        uint256 before = address(this).balance;
        try lottery.claimKeeperReward() {
            totalKeeperPaid += address(this).balance - before;
        } catch {}
    }

    /// @dev 覆盖 FR-C-29 逃生通道：卡死超 30 天的期可被任何人作废。
    ///      不加这两个 handler，新增的 ABANDONED 状态就是不变量测试里的死代码，
    ///      其记账错误不会被守恒检查发现（第 21 轮审计正是抓到过这类死路径）
    function abandon(uint256 pick) external {
        if (drawingRounds.length == 0) return;
        uint32 roundId = drawingRounds[bound(pick, 0, drawingRounds.length - 1)];
        (Lottery.RoundState st, uint64 closeTime,,,,,,,) = lottery.getRound(roundId);
        if (st != Lottery.RoundState.DRAWING) return;
        // 主动推进到可作废时刻。靠 skipTime 自然攒满 30 天在 fuzz 里不可达
        // （实测：默认深度下作废成功次数恒为 0；把 skipTime 上界放大到 40 天反而更糟，
        //  时间会跳过整个售票窗口，导致每期都零票作废）。handler 本就是测试驱动，
        //  这里推进时间不影响被检验的对象——记账正确性
        uint256 t = uint256(closeTime) + lottery.SEAL_GAP() + lottery.ABANDON_TIMEOUT();
        if (block.timestamp < t) vm.warp(t);
        abandonTried++;
        try lottery.abandonStuckRound(roundId) {
            abandonOk++;
        } catch {}
    }

    function refund(uint256 pick, uint256 rangeSeed) external {
        uint32 cur = lottery.s_currentRound();
        uint32 roundId = uint32(bound(pick, 1, cur));
        (Lottery.RoundState st,,,,,,,,) = lottery.getRound(roundId);
        if (st != Lottery.RoundState.ABANDONED) return;
        uint256 n = lottery.rangeCountOf(roundId);
        if (n == 0) return;
        uint256 idx = bound(rangeSeed, 0, n - 1);
        Lottery.TicketRange[] memory page = lottery.getRanges(roundId, idx, 1);
        if (page.length == 0) return;
        uint256[] memory idxs = new uint256[](1);
        idxs[0] = idx;
        address who = page[0].owner;
        uint256 before = who.balance;
        vm.prank(who);
        try lottery.refundAbandoned(roundId, idxs) {
            totalRefunded += who.balance - before;
        } catch {}
    }

    /// @dev 覆盖 VRF 重试路径（审计第二轮 B）：超时后追加请求，
    ///      两个 requestId 同时挂起时先到先得，不得造成重复结算或资金错乱
    function retryDraw(uint256 roundSeed) external {
        uint32 cur = lottery.s_currentRound();
        uint32 roundId = uint32(bound(roundSeed, 1, cur));
        try lottery.retryDraw(roundId) {} catch {}
    }
}

contract LotteryInvariantTest is Test {
    uint64 internal constant ANCHOR = 1_700_000_000;

    Lottery internal lottery;
    VRFCoordinatorV2_5Mock internal coordinator;
    LotteryHandler internal handler;
    address internal treasury = makeAddr("treasury");

    uint8[3] internal WINNER_COUNTS = [1, 2, 5];

    function setUp() public {
        vm.warp(ANCHOR + 1);
        coordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        uint256 subId = coordinator.createSubscription();
        coordinator.fundSubscription(subId, 100_000 ether);

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
            1e14,
            ANCHOR,
            intervals,
            treasury,
            100,
            tierBps,
            tierWinners
        );
        coordinator.addConsumer(subId, address(lottery));

        handler = new LotteryHandler(lottery, coordinator, treasury, subId);
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
        // s_pendingKeeperRewards 是 FR-C-30 记账但尚未领取的开奖奖励——
        // 它是从 s_accruedFees 里挪出来的，两者都是应付义务，必须同时计入
        uint256 obligations = lottery.s_accruedFees() + lottery.s_pendingPot()
            + lottery.s_pendingTier1() + lottery.s_pendingKeeperRewards();
        uint32 cur = lottery.s_currentRound();
        for (uint32 id = 1; id <= cur; id++) {
            (Lottery.RoundState st,,,, uint256 pot, uint256 carry,,,) = lottery.getRound(id);
            if (st == Lottery.RoundState.OPEN || st == Lottery.RoundState.DRAWING) {
                obligations += pot + carry;
            } else if (st == Lottery.RoundState.SETTLED) {
                obligations += _unclaimedOf(id);
            } else if (st == Lottery.RoundState.ABANDONED) {
                // 作废期的 pot 是「尚未被购票者取回的票款」，仍是应付义务（FR-C-29）
                obligations += pot;
            }
            // VOIDED 期的资金已全额转移到下期，贡献为 0
        }
        uint256 balance = address(lottery).balance;
        assertGe(balance, obligations, "solvency violated");
        assertEq(balance, obligations, "accounting leak detected");
    }

    /// @dev FR-T-03 不变量二：资金守恒——流入 == 在库 + 流出
    function invariant_Conservation() public view {
        assertEq(
            handler.totalBought() + handler.totalInjected(),
            address(lottery).balance + handler.totalPrizesPaid() + handler.totalFeesWithdrawn()
                + handler.totalRefunded() + handler.totalKeeperPaid(),
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

    /// @dev **确定性**覆盖 ABANDONED 分支的偿付性记账。
    ///
    ///      为什么不靠 fuzz：要凑齐「买票 → VRF 故障 → 开奖 → 过 30 天 → 作废 → 退款」
    ///      这 6 步有序动作，在随机 handler 里概率极低——实测探针显示成功次数长期为 0。
    ///      ABANDONED 是一个**持有资金**的新状态，它的记账必须被守恒检查真正走到，
    ///      而不是「handler 里有这个函数」就算数（第 21 轮审计抓到过这类假覆盖）。
    ///      这里手工驱动一遍，再调用同一条偿付性断言。
    function test_SolvencyHoldsAcrossAbandonAndRefund() public {
        handler.createStuckRound(20);
        invariant_SolvencyExact();

        handler.abandon(0);
        invariant_SolvencyExact(); // 作废后：pot 变成「待退款」，carry 已回缓冲

        handler.refund(1, 0);
        invariant_SolvencyExact(); // 部分退款后仍然精确成立
        assertGt(handler.totalRefunded(), 0, "the refund path must actually execute");
    }

    /// @dev **确定性**覆盖 FR-C-30 的记账。同样不靠 fuzz 碰运气：
    ///      未领取的开奖奖励是一笔真实的应付义务，必须被守恒检查真正走到
    function test_SolvencyHoldsAcrossKeeperReward() public {
        handler.buy(0, 200);
        handler.draw(); // handler 自己触发，奖励记在它名下
        invariant_SolvencyExact();

        assertGt(lottery.s_pendingKeeperRewards(), 0, "reward must actually accrue");
        handler.claimKeeperReward();
        invariant_SolvencyExact();
        assertGt(handler.totalKeeperPaid(), 0, "the reward payout path must actually execute");
        assertEq(lottery.s_pendingKeeperRewards(), 0);
    }
}
