// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 前端依赖的视图函数（多为审计后新增，用于消除「界面说 A、链上是 B」）
contract LotteryViewsTest is LotteryTestBase {
    /// @dev feeBpsOf 返回开期快照，而非可被 owner 随时改动的全局值
    function test_FeeBpsOfReturnsRoundSnapshot() public {
        assertEq(lottery.feeBpsOf(1), FEE_BPS);
        lottery.setFeeBps(1000); // 改全局
        assertEq(lottery.feeBpsOf(1), FEE_BPS, "round 1 keeps its snapshot");
        assertEq(lottery.s_feeBps(), 1000);

        _buy(alice, 10);
        _settleRound(1, 42);
        assertEq(lottery.feeBpsOf(2), 1000, "round 2 snapshots the new rate");
    }

    /// @dev distributableEstimate 反映配比释放后的实际可分配上限
    function test_DistributableEstimateReflectsCarryCap() public {
        token.mint(carol, 1000e6);
        vm.startPrank(carol);
        token.approve(address(lottery), 1000e6);
        lottery.injectPot(1, 1000e6);
        vm.stopPrank();

        // 尚无自售 → carry 一分也不可分配
        assertEq(lottery.distributableEstimate(1), 0, "no self sales, no carry unlocked");

        _buy(bob, 10); // 自售净额 9.9
        // 可分配 = 自售 9.9 + 等额解锁的 carry 9.9
        assertEq(lottery.distributableEstimate(1), 99e5 * 2, "capped by stake multiple");
        assertLt(lottery.distributableEstimate(1), _potOf(1), "far below the face-value pot");
    }

    /// @dev claimDeadlineOf 未结算期返回 0，结算后返回结算时刻 + 窗口
    function test_ClaimDeadlineOf() public {
        (uint64 settledAt, uint64 deadline) = lottery.claimDeadlineOf(1);
        assertEq(settledAt, 0);
        assertEq(deadline, 0, "unsettled round has no deadline");

        _buy(alice, 10);
        _settleRound(1, 42);
        (settledAt, deadline) = lottery.claimDeadlineOf(1);
        assertEq(settledAt, uint64(block.timestamp));
        assertEq(deadline, settledAt + lottery.CLAIM_WINDOW());
    }

    /// @dev getRanges 分页：边界、越界、以及「读到底」的自然写法不得溢出
    function test_GetRangesPagination() public {
        _buy(alice, 5);
        _buy(bob, 5);
        _buy(carol, 5);
        assertEq(lottery.rangeCountOf(1), 3);

        Lottery.TicketRange[] memory page = lottery.getRanges(1, 0, 2);
        assertEq(page.length, 2);
        assertEq(page[0].owner, alice);
        assertEq(page[1].owner, bob);

        page = lottery.getRanges(1, 2, 10); // limit 超出剩余
        assertEq(page.length, 1);
        assertEq(page[0].owner, carol);

        page = lottery.getRanges(1, 5, 10); // offset 越界
        assertEq(page.length, 0);

        // 「从 offset 读到底」的自然写法不得因 offset+limit 溢出而 panic
        page = lottery.getRanges(1, 1, type(uint256).max);
        assertEq(page.length, 2, "reading to the end must not overflow");
    }

    /// @dev salesOpenFor 反映开期快照
    function test_SalesOpenFor() public {
        assertTrue(lottery.salesOpenFor(1));
        lottery.setSalesPaused(true);
        assertTrue(lottery.salesOpenFor(1), "already-open round unaffected");

        _buy(alice, 10);
        _settleRound(1, 42);
        assertFalse(lottery.salesOpenFor(2), "next round opened while paused");
    }

    /// @dev carriedPotOf 在 VOIDED 期归零（资金已转入缓冲）
    function test_CarriedPotClearedOnVoid() public {
        token.mint(carol, 500e6);
        vm.startPrank(carol);
        token.approve(address(lottery), 500e6);
        lottery.injectPot(1, 500e6);
        vm.stopPrank();
        assertEq(lottery.carriedPotOf(1), 500e6);

        vm.warp(_drawTimeOf(1));
        lottery.performUpkeep(""); // 零购票 → VOIDED
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.VOIDED));
        assertEq(lottery.carriedPotOf(1), 0, "no stale carriedPot on a voided round");
        assertEq(_potOf(1), 0, "funds moved out");
    }
}
