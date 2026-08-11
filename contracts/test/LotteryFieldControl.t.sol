// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 攻击者合约：原子地 performUpkeep + buyTickets，试图抢占极短窗口
contract WindowSniper {
    Lottery immutable lottery;

    constructor(Lottery l) {
        lottery = l;
    }

    function snipe(uint32 qty, uint256 price) external {
        lottery.performUpkeep("");
        lottery.buyTickets{value: price * qty}(qty);
    }

    receive() external payable {}
}

/// @dev 安全回归（2026-08-10 第三轮审计）：操纵「参与者集合」的两条路径。
///      与首轮 Critical（操纵随机数）同类——都不是偷钱，而是把概率性中奖变成确定性获取。
///      #1 owner 用 setSalesPaused 全程清场、末秒解禁自购（PoC：花 8 赢 106.92）
///      #2 keeper 缺席时任何人可择时把新期售票窗口压到 1 秒并独占
contract LotteryFieldControlTest is LotteryTestBase {
    /// @dev #1 核心回归：暂停对「已开出的期」无效，owner 无法中途清场
    function test_PauseCannotClearFieldOfOpenRound() public {
        _buy(alice, 10); // 本期已开出且未暂停
        lottery.setSalesPaused(true);

        // 其他人照常可买本期——owner 无法把场子清空给自己
        vm.deal(bob, bob.balance + (8e14));
        vm.startPrank(bob);
        lottery.buyTickets{value: PRICE * 8}(8); // 不 revert
        vm.stopPrank();
        assertEq(lottery.ticketsOwned(1, bob), 8);
    }

    /// @dev #1：暂停在「下一期开出时」才生效，且届时对所有人一视同仁（owner 自己也买不了）
    function test_PauseAppliesToNextRoundForEveryoneIncludingOwner() public {
        _buy(alice, 10);
        lottery.setSalesPaused(true);
        _settleRound(1, 42); // 开出第 2 期时快照 paused=true

        assertFalse(lottery.salesOpenFor(2), "round 2 opened while paused");

        // 其他人买不了
        vm.deal(bob, bob.balance + (8e14));
        vm.startPrank(bob);
        vm.expectRevert(Lottery.SalesArePaused.selector);
        lottery.buyTickets{value: PRICE * 8}(8);
        vm.stopPrank();

        // owner 解禁后自己也买不了这一期（快照已定死），无法独占
        lottery.setSalesPaused(false);
        vm.deal(address(this), address(this).balance + (8e14));
        vm.expectRevert(Lottery.SalesArePaused.selector);
        lottery.buyTickets{value: PRICE * 8}(8);
    }

    /// @dev #2 核心回归：新期售票窗口不得短于 MIN_SALES_WINDOW，无法被择时压缩
    function test_SalesWindowCannotBeSnipedShort() public {
        _buy(alice, 10);
        // keeper 缺席，攻击者卡在「距下一场次仅 1 秒」时触发
        uint64 nextSlot = _closeTimeOf(1) + 2 days;
        vm.warp(nextSlot - 1);

        WindowSniper sniper = new WindowSniper(lottery);
        vm.deal(address(sniper), address(sniper).balance + (8e14));
        sniper.snipe(8, PRICE);

        uint32 sniped = lottery.s_currentRound();
        uint64 window = _closeTimeOf(sniped) - uint64(block.timestamp);
        assertGe(window, lottery.MIN_SALES_WINDOW(), "window must respect the floor");

        // 其他人仍有充足时间进场
        vm.warp(block.timestamp + 10 minutes);
        vm.deal(bob, bob.balance + (8e14));
        vm.startPrank(bob);
        lottery.buyTickets{value: PRICE * 8}(8); // 不 revert
        vm.stopPrank();
    }

    /// @dev 参与度门槛：票数不足时滚存/注资不予分配，退回缓冲区顺延
    function test_CarryHeldBackWhenParticipationTooLow() public {
        // 注资一大笔到第 1 期
        _inject(carol, 1, 200e14);
        assertEq(lottery.carriedPotOf(1), 200e14, "injection counted as carried");

        // 只买 8 张（远低于门槛 100）→ 注资不分配
        _buy(bob, 8);
        _settleRound(1, 7);

        // 自售额解锁等额 carry，其余退回缓冲（配比释放，FR-C-27）
        uint256 selfSold = uint256(8e14) * (10000 - uint256(FEE_BPS)) / 10000;
        assertEq(
            lottery.s_pendingPot(), 200e14 - selfSold, "excess beyond stake returned to buffer"
        );
        // bob 只赢到自己 8 张票的自售奖池（7.92），拿不到 200 注资
        uint256 before = bob.balance;
        vm.startPrank(bob);
        lottery.claim(1, 0);
        lottery.claim(1, 1);
        lottery.claim(1, 2);
        vm.stopPrank();
        uint256 won = bob.balance - before;
        assertLe(won, 8e14 * 2, "capture bounded by own stake, not the whole injection");
        assertLt(won, 200e14, "cannot drain the injection");
    }

    /// @dev 参与度达标时滚存正常分配（门槛不影响正常玩法）
    function test_CarryDistributedWhenParticipationSufficient() public {
        _inject(carol, 1, 50e14);

        _buy(alice, 100); // 达到门槛
        _settleRound(1, 7);

        assertEq(lottery.s_pendingPot(), 0, "carry distributed, nothing held back");
        // pot = 99（自售净额） + 50（注资）= 149，一等奖 60%
        assertEq(lottery.perWinnerAmount(1, 0), (149e14 * 6000) / 10000);
    }
}
