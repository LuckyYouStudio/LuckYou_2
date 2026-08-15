// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 恶意中奖者：原生币到账会自动执行 receive()，在此重入 claim。
///      注意这比 ERC20 时代更危险——ERC20 转账不回调接收方，必须构造恶意 token
///      才能触发；改用原生 ETH 后，任何合约地址收款都会执行自己的代码（FR-C-03）
contract ReentrantWinner {
    Lottery public immutable lottery;
    uint32 public targetRound;
    uint8 public targetTier;
    bool public reentered;
    bool public innerSucceeded;
    bytes public innerError;

    constructor(Lottery lottery_) {
        lottery = lottery_;
    }

    function buy(uint32 qty, uint256 price) external {
        uint32 _rid1 = lottery.s_currentRound();
        lottery.buyTickets{value: price * qty}(qty, _rid1);
    }

    function attack(uint32 roundId, uint8 tier) external {
        targetRound = roundId;
        targetTier = tier;
        lottery.claim(roundId, tier);
    }

    receive() external payable {
        if (reentered) return;
        reentered = true;
        try lottery.claim(targetRound, targetTier) {
            innerSucceeded = true;
        } catch (bytes memory err) {
            innerError = err;
        }
    }
}

/// @dev 拒收原生币的合约：验证转账失败会 revert 而非静默吞掉（FR-C-02）
contract RejectingReceiver {
    Lottery public immutable lottery;

    constructor(Lottery lottery_) {
        lottery = lottery_;
    }

    function buy(uint32 qty, uint256 price) external {
        uint32 _rid2 = lottery.s_currentRound();
        lottery.buyTickets{value: price * qty}(qty, _rid2);
    }

    function claim(uint32 roundId, uint8 tier) external {
        lottery.claim(roundId, tier);
    }
    // 刻意不写 receive/fallback：收款必失败
}

/// @dev FR-T-04 攻击场景测试
contract LotteryAttackTest is LotteryTestBase {
    /// @dev 重入 claim：中奖者是合约、收款时自动重入，必须被 ReentrancyGuard 拦下且只付一次
    function test_Attack_ReentrantClaimBlocked() public {
        ReentrantWinner attacker = new ReentrantWinner(lottery);
        vm.deal(address(attacker), 100 * PRICE);
        attacker.buy(10, PRICE); // 独占全部票，必中所有奖级

        _settleRound(1, 42);

        uint256 perWinner = lottery.perWinnerAmount(1, 0);
        uint256 balBefore = address(attacker).balance;
        attacker.attack(1, 0);

        assertTrue(attacker.reentered(), "receive() must have fired on native transfer");
        assertFalse(attacker.innerSucceeded(), "reentrant claim must not succeed");
        assertEq(
            bytes4(attacker.innerError()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "must be blocked by ReentrancyGuard"
        );
        assertEq(address(attacker).balance - balBefore, perWinner, "paid exactly once");
    }

    /// @dev 收款方拒收时，claim 必须 revert（钱留在合约里可再试），不得静默失败
    function test_Attack_RejectingReceiverRevertsClaim() public {
        RejectingReceiver r = new RejectingReceiver(lottery);
        vm.deal(address(r), 100 * PRICE);
        r.buy(10, PRICE);
        _settleRound(1, 42);

        uint256 balBefore = address(lottery).balance;
        vm.expectRevert(Lottery.TransferFailed.selector);
        r.claim(1, 0);
        assertEq(address(lottery).balance, balBefore, "funds untouched on failed transfer");
    }

    /// @dev 多付/少付都必须 revert，合约不自动退差额（FR-C-03）
    function test_Attack_IncorrectPaymentRejected() public {
        vm.deal(alice, 100 * PRICE);
        uint32 _rid3 = lottery.s_currentRound();
        vm.startPrank(alice);
        vm.expectRevert(Lottery.IncorrectPayment.selector);
        lottery.buyTickets{value: PRICE * 10 + 1}(10, _rid3); // 多付 1 wei
        uint32 _rid4 = lottery.s_currentRound();
        vm.expectRevert(Lottery.IncorrectPayment.selector);
        lottery.buyTickets{value: PRICE * 10 - 1}(10, _rid4); // 少付 1 wei
        vm.stopPrank();
        assertEq(address(lottery).balance, 0, "no funds accepted");
    }

    /// @dev closeTime 边界抢跑：截止前 1 秒可买，到点即拒
    function test_Attack_CloseTimeBoundarySnipe() public {
        vm.deal(alice, alice.balance + (2e14));
        vm.startPrank(alice);
        vm.warp(_closeTimeOf(1) - 1);
        uint32 _rid5 = lottery.s_currentRound();
        lottery.buyTickets{value: PRICE * 1}(1, _rid5); // 边界前一秒：允许

        vm.warp(_closeTimeOf(1));
        uint32 _rid6 = lottery.s_currentRound();
        vm.expectRevert(Lottery.SalesClosed.selector);
        lottery.buyTickets{value: PRICE * 1}(1, _rid6); // 到达停售时刻：拒绝（即使 keeper 未执行）
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
        lottery.injectPot{value: 0}(1);
    }

    /// @dev 审计 #5：注资与购票共用同一时间闸，封盘后不得再改变本期奖池规模
    function test_RevertWhen_InjectAfterCloseTime() public {
        vm.deal(alice, alice.balance + (10e14));
        vm.startPrank(alice);
        vm.warp(_closeTimeOf(1)); // 封盘期：state 仍是 OPEN，但已停售
        vm.expectRevert(Lottery.SalesClosed.selector);
        lottery.injectPot{value: 10e14}(1);
        vm.stopPrank();
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

    function test_RevertWhen_ConstructorZeroPrice() public {
        vm.expectRevert(Lottery.InvalidTicketPrice.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
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

        vm.warp(_settledAtOf(1) + 90 days + 1);
        lottery.rolloverExpired(1); // 不 revert
    }
}
