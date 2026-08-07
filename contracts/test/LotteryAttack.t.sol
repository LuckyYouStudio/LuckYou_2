// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Lottery} from "../src/Lottery.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 带转账回调的恶意 ERC20：给 attacker 转账时触发其钩子（模拟 ERC777 风格重入）
contract ReentrantToken is MockERC20 {
    address public attacker;

    constructor() MockERC20("Evil Token", "EVIL", 6) {}

    function setAttacker(address attacker_) external {
        attacker = attacker_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (to == attacker && attacker.code.length > 0) {
            ReentrantAttacker(attacker).onPayout();
        }
        return ok;
    }
}

/// @dev 攻击者合约：收到奖金转账时立刻重入 claim
contract ReentrantAttacker {
    Lottery public immutable lottery;
    ReentrantToken public immutable token;
    uint32 public targetRound;
    uint8 public targetTier;
    bool public reentered;
    bool public innerSucceeded;
    bytes public innerError;

    constructor(Lottery lottery_, ReentrantToken token_) {
        lottery = lottery_;
        token = token_;
    }

    function buy(uint32 qty) external {
        token.approve(address(lottery), type(uint256).max);
        lottery.buyTickets(qty);
    }

    function attack(uint32 roundId, uint8 tier) external {
        targetRound = roundId;
        targetTier = tier;
        lottery.claim(roundId, tier);
    }

    function onPayout() external {
        if (reentered) return;
        reentered = true;
        try lottery.claim(targetRound, targetTier) {
            innerSucceeded = true;
        } catch (bytes memory err) {
            innerError = err;
        }
    }
}

/// @dev FR-T-04 攻击场景测试
contract LotteryAttackTest is LotteryTestBase {
    /// @dev 重入 claim：内层调用必须被 ReentrancyGuard 拦截，且只支付一次
    function test_Attack_ReentrantClaimBlocked() public {
        ReentrantToken evil = new ReentrantToken();
        Lottery evilLottery = new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            address(evil),
            PRICE,
            ANCHOR,
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
        coordinator.addConsumer(subId, address(evilLottery));

        ReentrantAttacker attacker = new ReentrantAttacker(evilLottery, evil);
        evil.setAttacker(address(attacker));
        evil.mint(address(attacker), 10e6);
        attacker.buy(10); // 独占全部票，必中所有奖级

        vm.warp(ANCHOR + 2 days + 75 minutes);
        evilLottery.performUpkeep("");
        (uint256 requestId,) = evilLottery.vrfRequestOf(1);
        uint256[] memory words = new uint256[](1);
        words[0] = 42;
        coordinator.fulfillRandomWordsWithOverride(requestId, address(evilLottery), words);

        uint256 perWinner = evilLottery.perWinnerAmount(1, 0);
        attacker.attack(1, 0);

        assertTrue(attacker.reentered(), "callback must have fired");
        assertFalse(attacker.innerSucceeded(), "reentrant claim must not succeed");
        assertEq(
            bytes4(attacker.innerError()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "must be blocked by ReentrancyGuard"
        );
        assertEq(evil.balanceOf(address(attacker)), perWinner, "paid exactly once");
    }

    /// @dev closeTime 边界抢跑：截止前 1 秒可买，到点即拒
    function test_Attack_CloseTimeBoundarySnipe() public {
        token.mint(alice, 2e6);
        vm.startPrank(alice);
        token.approve(address(lottery), 2e6);

        vm.warp(_closeTimeOf(1) - 1);
        lottery.buyTickets(1); // 边界前一秒：允许

        vm.warp(_closeTimeOf(1));
        vm.expectRevert(Lottery.SalesClosed.selector);
        lottery.buyTickets(1); // 到达停售时刻：拒绝（即使 keeper 未执行）
        vm.stopPrank();
    }

    /// @dev owner 无法把费率设到上限以上（FR-T-04），已在单元测试覆盖，此处补 owner 越权面
    function test_Attack_OwnerCannotExceedFeeCapNorTouchPot() public {
        _buy(alice, 100);
        vm.expectRevert(Lottery.FeeTooHigh.selector);
        lottery.setFeeBps(1001);
        // FR-C-24：合约不存在任何能动到奖池的管理员函数——
        // 唯一的资金出口是 claim（中奖者）与 withdrawFees（只到 treasury）
        uint256 potBefore = _potOf(1);
        lottery.setSalesPaused(true);
        lottery.setTreasury(makeAddr("newTreasury"));
        lottery.setFeeBps(1000);
        assertEq(_potOf(1), potBefore, "admin ops must not move pot");
    }
}

/// @dev 覆盖率补齐：revert 分支与边角
contract LotteryEdgeTest is LotteryTestBase {
    function test_RevertWhen_ClaimNotSettled() public {
        _buy(alice, 1);
        vm.prank(alice);
        vm.expectRevert(Lottery.RoundNotSettled.selector);
        lottery.claim(1, 0);
    }

    function test_RevertWhen_ClaimInvalidTier() public {
        _buy(alice, 10);
        _settleRound(1, 42);
        vm.prank(alice);
        vm.expectRevert(Lottery.InvalidTier.selector);
        lottery.claim(1, 3);
    }

    function test_RevertWhen_RetryOnNonDrawingRound() public {
        vm.expectRevert(Lottery.RoundNotDrawing.selector);
        lottery.retryDraw(1);
    }

    function test_RevertWhen_WithdrawZeroFees() public {
        vm.expectRevert(Lottery.NoFeesToWithdraw.selector);
        lottery.withdrawFees();
    }

    function test_RevertWhen_SetTreasuryZero() public {
        vm.expectRevert(Lottery.InvalidTreasury.selector);
        lottery.setTreasury(address(0));
    }

    function test_RevertWhen_InjectZero() public {
        vm.expectRevert(Lottery.InvalidQuantity.selector);
        lottery.injectPot(1, 0);
    }

    function test_RevertWhen_WinnersOfUnsettled() public {
        vm.expectRevert(Lottery.RoundNotSettled.selector);
        lottery.winnersOf(1);
    }

    function test_PendingPrizes_EmptyForOpenRound() public {
        _buy(alice, 5);
        uint256[] memory amounts = lottery.pendingPrizes(1, alice);
        for (uint256 i = 0; i < amounts.length; i++) {
            assertEq(amounts[i], 0);
        }
    }

    function test_RevertWhen_ConstructorZeroToken() public {
        vm.expectRevert(Lottery.InvalidToken.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            address(0),
            PRICE,
            ANCHOR,
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
    }

    function test_RevertWhen_ConstructorZeroPrice() public {
        vm.expectRevert(Lottery.InvalidTicketPrice.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            address(token),
            0,
            ANCHOR,
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
    }

    function test_RevertWhen_ConstructorZeroTreasury() public {
        vm.expectRevert(Lottery.InvalidTreasury.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            address(token),
            PRICE,
            ANCHOR,
            _intervals(),
            address(0),
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
    }

    function test_RevertWhen_ConstructorEmptyIntervals() public {
        uint32[] memory none = new uint32[](0);
        vm.expectRevert(Lottery.InvalidSchedule.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            address(token),
            PRICE,
            ANCHOR,
            none,
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
    }

    function test_RevertWhen_ConstructorTierMismatchOrZeroWinners() public {
        uint8[] memory shortWinners = new uint8[](2);
        shortWinners[0] = 1;
        shortWinners[1] = 2;
        vm.expectRevert(Lottery.InvalidTierConfig.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            address(token),
            PRICE,
            ANCHOR,
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            shortWinners
        );

        uint8[] memory zeroWinners = _tierWinners();
        zeroWinners[1] = 0;
        vm.expectRevert(Lottery.InvalidTierConfig.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            address(token),
            PRICE,
            ANCHOR,
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            zeroWinners
        );
    }

    function test_RevertWhen_ConstructorTooManySlots() public {
        uint8[] memory fatWinners = _tierWinners();
        fatWinners[2] = 14; // 1 + 2 + 14 = 17 > 16
        vm.expectRevert(Lottery.InvalidTierConfig.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            address(token),
            PRICE,
            ANCHOR,
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            fatWinners
        );
    }

    /// @dev 暂停状态下 retryDraw / rolloverExpired 也不受影响（FR-C-23 全面验证）
    function test_PauseDoesNotAffectRetryAndRollover() public {
        _buy(alice, 10);
        _triggerDraw(1);
        lottery.setSalesPaused(true);

        vm.warp(block.timestamp + 3 hours);
        lottery.retryDraw(1); // 不 revert
        _fulfill(1, 42);

        vm.warp(_closeTimeOf(1) + 90 days + 1);
        lottery.rolloverExpired(1); // 不 revert
    }
}
