// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 安全回归（2026-08-10 第四轮审计）：
///      ① 领奖窗口锚点——结算延迟不得吃掉中奖者的领奖时间
///      ② 费率开期快照——owner 不得抢跑购票临时抬高抽成
contract LotteryOwnerTimingTest is LotteryTestBase {
    /// @dev 核心回归：keeper/VRF 停摆 91 天后才结算，中奖者仍有完整领奖窗口
    function test_DelayedSettlementStillGivesFullClaimWindow() public {
        _buy(alice, 10);

        vm.warp(_drawTimeOf(1) + 91 days); // 长时间停摆
        lottery.performUpkeep("");
        _fulfill(1, 42);

        (, address[] memory winners,) = lottery.winnersOf(1);
        assertEq(winners[0], alice);

        uint256 before = alice.balance;
        vm.prank(alice);
        lottery.claim(1, 0); // 修复前这里 revert ClaimWindowClosed
        assertGt(alice.balance - before, 0, "winner can still claim after delayed settlement");
    }

    /// @dev 结算延迟期间，第三方无法提前把奖金扫走
    function test_RolloverCannotSweepBeforeWindowFromSettlement() public {
        _buy(alice, 10);
        vm.warp(_drawTimeOf(1) + 91 days);
        lottery.performUpkeep("");
        _fulfill(1, 42);

        vm.prank(bob);
        vm.expectRevert(Lottery.ClaimWindowNotClosed.selector);
        lottery.rolloverExpired(1);
    }

    /// @dev 窗口自结算起满 90 天后才可滚存，与 claim 严格互斥
    function test_RolloverAllowedAfterWindowFromSettlement() public {
        _buy(alice, 10);
        _settleRound(1, 42);
        uint64 settledAt = uint64(block.timestamp);

        vm.warp(settledAt + 90 days);
        vm.expectRevert(Lottery.ClaimWindowNotClosed.selector);
        lottery.rolloverExpired(1);

        vm.warp(settledAt + 90 days + 1);
        lottery.rolloverExpired(1); // 不 revert
        assertGt(lottery.s_pendingPot(), 0);
    }

    /// @dev 核心回归：owner 抢跑抬高费率，对已开出期的购票无效
    function test_FeeHikeCannotFrontrunOpenRoundPurchases() public {
        // 第 1 期以 1% 开出
        assertEq(lottery.s_feeBps(), FEE_BPS);

        // owner 抢跑，把费率抬到上限
        lottery.setFeeBps(1000);

        // 受害者购票：仍按开期时的 1% 计费
        vm.deal(bob, bob.balance + (1000e14));
        uint32 _rid1 = lottery.s_currentRound();
        vm.startPrank(bob);
        lottery.buyTickets{value: PRICE * 1000}(1000, _rid1);
        vm.stopPrank();

        assertEq(lottery.s_accruedFees(), 10e14, "fee charged at the rate snapshotted at open");
        assertEq(_potOf(1), 990e14, "pot keeps 99%, not 90%");
    }

    /// @dev 费率变更在下一期开出时生效（正常调价路径不受影响）
    function test_FeeChangeAppliesFromNextRound() public {
        lottery.setFeeBps(500); // 5%
        _buy(alice, 100); // 第 1 期仍按 1%
        assertEq(lottery.s_accruedFees(), 1e14);

        _settleRound(1, 42); // 开出第 2 期，快照 5%
        // 开奖同时按 FR-C-30 把第 1 期抽成的一部分划给了触发者，
        // 因此下面的期望必须扣掉这笔——它没有消失，只是进了另一个桶
        uint256 keeperCut = lottery.s_pendingKeeperRewards();
        assertGt(keeperCut, 0, "sanity: the draw did pay a keeper reward");

        uint32 r = lottery.s_currentRound();
        _buy(bob, 100);
        // 第 2 期按 5% 计费：100 张票款 * 5%
        assertEq(
            lottery.s_accruedFees(), 1e14 - keeperCut + 5e14, "new rate applies to the next round"
        );
        assertEq(_potOf(r), 95e14);
    }
}
