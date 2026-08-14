// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev FR-C-29 卡死逃生通道（SPEC Q9 方案 C）。
///      它兜的是**任何原因**导致的卡死——VRF 停摆、LINK 烧光、coordinator 变更、
///      乃至尚未发现的 bug——因此是唯一不依赖「我们把失效模式列全」的保护。
///      对应地，它绝不能变成一条提前退出的捷径，下面的边界测试就是在钉这一点。
contract LotteryAbandonTest is LotteryTestBase {
    /// @dev 把某期推进到 DRAWING 且 VRF 无法履约的状态
    function _stickRound(uint32 qty) internal returns (uint32 roundId) {
        roundId = lottery.s_currentRound();
        _buy(alice, qty);
        coordinator.removeConsumer(subId, address(lottery)); // 请求会失败
        vm.warp(_drawTimeOf(roundId));
        lottery.performUpkeep("");
        assertEq(uint8(_stateOf(roundId)), uint8(Lottery.RoundState.DRAWING));
    }

    function _abandonTime(uint32 roundId) internal view returns (uint64) {
        return _closeTimeOf(roundId) + lottery.SEAL_GAP() + lottery.ABANDON_TIMEOUT();
    }

    /// @dev 阈值之前一秒都不能作废——否则它就成了「随时可退票」，破坏彩票语义
    function test_RevertWhen_AbandonBeforeTimeout() public {
        uint32 r = _stickRound(10);
        vm.warp(_abandonTime(r) - 1);
        vm.expectRevert(Lottery.AbandonTooEarly.selector);
        lottery.abandonStuckRound(r);
    }

    /// @dev 只有 DRAWING 的期能被作废；已结算的期必须走正常领奖
    function test_RevertWhen_AbandonSettledRound() public {
        _buy(alice, 10);
        _settleRound(1, 42);
        vm.warp(block.timestamp + 60 days);
        vm.expectRevert(Lottery.RoundNotDrawing.selector);
        lottery.abandonStuckRound(1);
    }

    /// @dev 计时锚点必须是**原定开奖时刻**，不能是 drawRequestedAt——
    ///      后者会被 retryDraw 刷新，攻击者每 3 小时重试一次就能把逃生通道永久锁死
    function test_RetryDrawCannotPostponeAbandonment() public {
        uint32 r = _stickRound(10);

        // 在 30 天里反复 retryDraw（每次都会刷新 drawRequestedAt）
        coordinator.addConsumer(subId, address(lottery)); // 让 retryDraw 能成功发出请求
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 5 days);
            lottery.retryDraw(r);
        }

        // 到了原定开奖时刻 + 30 天，照样可以作废
        vm.warp(_abandonTime(r));
        lottery.abandonStuckRound(r);
        assertEq(uint8(_stateOf(r)), uint8(Lottery.RoundState.ABANDONED));
    }

    /// @dev 退款金额必须与购票时的算式逐笔一致（不是批量公式），且全部退完恰好清空 pot
    function test_RefundIsExactAndDrainsPotToZero() public {
        uint32 r = lottery.s_currentRound();
        // 三笔不同大小的购买 → 三条 Range，覆盖取整
        _buy(alice, 7);
        _buy(bob, 3);
        _buy(alice, 11);
        coordinator.removeConsumer(subId, address(lottery));
        vm.warp(_drawTimeOf(r));
        lottery.performUpkeep("");
        vm.warp(_abandonTime(r));
        lottery.abandonStuckRound(r);

        uint256 aliceBefore = alice.balance;
        uint256[] memory aliceIdx = new uint256[](2);
        aliceIdx[0] = 0;
        aliceIdx[1] = 2;
        vm.prank(alice);
        lottery.refundAbandoned(r, aliceIdx);
        uint256 expAlice = _net(7) + _net(11);
        assertEq(alice.balance - aliceBefore, expAlice, "alice refunded exactly her net cost");

        uint256 bobBefore = bob.balance;
        uint256[] memory bobIdx = new uint256[](1);
        bobIdx[0] = 1;
        vm.prank(bob);
        lottery.refundAbandoned(r, bobIdx);
        assertEq(bob.balance - bobBefore, _net(3), "bob refunded exactly his net cost");

        // 全部退完后该期账面归零：证明退款总额 == 自售净额，分文不差
        (,,,, uint256 pot,,,,) = lottery.getRound(r);
        assertEq(pot, 0, "refunds exactly exhaust the round pot");
        // FR-C-30 之后抽成会拆成两个桶：一部分留在 s_accruedFees，
        // 一部分作为开奖奖励记到 s_pendingKeeperRewards。钱没少，只是换了口袋，
        // 所以这里必须把两个都算上——否则会误判成资金泄漏
        assertEq(
            address(lottery).balance,
            lottery.s_accruedFees() + lottery.s_pendingKeeperRewards(),
            "only fees (incl. accrued keeper rewards) remain"
        );
    }

    /// @dev 同一条 Range 不得重复退款
    function test_RevertWhen_RefundTwice() public {
        uint32 r = _stickRound(10);
        vm.warp(_abandonTime(r));
        lottery.abandonStuckRound(r);
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.prank(alice);
        lottery.refundAbandoned(r, idx);
        assertTrue(lottery.rangeRefunded(r, 0));

        vm.prank(alice);
        vm.expectRevert(Lottery.AlreadyRefunded.selector);
        lottery.refundAbandoned(r, idx);
    }

    /// @dev 不得替别人退款到自己口袋
    function test_RevertWhen_RefundSomeoneElsesRange() public {
        uint32 r = _stickRound(10);
        vm.warp(_abandonTime(r));
        lottery.abandonStuckRound(r);
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0; // alice 的 Range
        vm.prank(bob);
        vm.expectRevert(Lottery.NotRangeOwner.selector);
        lottery.refundAbandoned(r, idx);
    }

    /// @dev 未作废的期不得退款
    function test_RevertWhen_RefundNonAbandonedRound() public {
        _buy(alice, 10);
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.prank(alice);
        vm.expectRevert(Lottery.RoundNotAbandoned.selector);
        lottery.refundAbandoned(1, idx);
    }

    /// @dev 非自售部分（注资 / 滚存承接）不属于购票者，必须退回缓冲区
    function test_CarryGoesBackToBufferNotToBuyers() public {
        uint32 r = lottery.s_currentRound();
        _inject(carol, r, 500e14); // 注资 —— 计入 carriedPot
        _buy(alice, 10);
        coordinator.removeConsumer(subId, address(lottery));
        vm.warp(_drawTimeOf(r));
        lottery.performUpkeep("");
        vm.warp(_abandonTime(r));

        uint256 bufBefore = lottery.s_pendingPot();
        lottery.abandonStuckRound(r);
        assertEq(lottery.s_pendingPot() - bufBefore, 500e14, "injection returned to buffer");

        // alice 只拿回自己的票款，拿不到那 500 的注资
        uint256 before = alice.balance;
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        vm.prank(alice);
        lottery.refundAbandoned(r, idx);
        assertEq(alice.balance - before, _net(10), "buyer gets only their own ticket money");
    }

    /// @dev 作废期不得再被当成正常期使用
    function test_AbandonedRoundIsInert() public {
        uint32 r = _stickRound(10);
        vm.warp(_abandonTime(r));
        lottery.abandonStuckRound(r);

        vm.expectRevert(Lottery.RoundNotDrawing.selector);
        lottery.abandonStuckRound(r); // 不能重复作废
        vm.expectRevert(Lottery.RoundNotDrawing.selector);
        lottery.retryDraw(r);
        vm.expectRevert(Lottery.RoundNotSettled.selector);
        lottery.claim(r, 0);
    }

    /// @dev 性质：任意购买组合下，退款总额恒等于该期自售净额（守恒，无泄漏也无超发）
    function testFuzz_RefundsExactlyEqualSelfSold(uint8 a, uint8 b, uint8 c) public {
        uint32 qa = uint32(bound(a, 1, 50));
        uint32 qb = uint32(bound(b, 1, 50));
        uint32 qc = uint32(bound(c, 1, 50));
        uint32 r = lottery.s_currentRound();
        _buy(alice, qa);
        _buy(bob, qb);
        _buy(carol, qc);

        (,,,, uint256 potBefore,,,,) = lottery.getRound(r);
        coordinator.removeConsumer(subId, address(lottery));
        vm.warp(_drawTimeOf(r));
        lottery.performUpkeep("");
        vm.warp(_abandonTime(r));
        lottery.abandonStuckRound(r);

        uint256 paid;
        address[3] memory who = [alice, bob, carol];
        for (uint256 i = 0; i < 3; i++) {
            uint256[] memory idx = new uint256[](1);
            idx[0] = i;
            uint256 before = who[i].balance;
            vm.prank(who[i]);
            lottery.refundAbandoned(r, idx);
            paid += who[i].balance - before;
        }
        assertEq(paid, potBefore, "sum of refunds == self-sold net exactly");
        (,,,, uint256 potAfter,,,,) = lottery.getRound(r);
        assertEq(potAfter, 0);
    }

    /// @dev 与购票时完全相同的算式（刻意不写成批量公式，以复现同样的取整）
    function _net(uint32 qty) internal view returns (uint256) {
        uint256 cost = PRICE * qty;
        return cost - (cost * FEE_BPS) / 10000;
    }
}
