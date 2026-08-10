// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 安全回归（2026-08-10 第四轮审计）：VRF 回调 gas 必须与 range 数无关。
///      此前回调内调 _deriveWinners 做 slots 次二分查找，gas 随 log(ranges) 增长；
///      高 slot 配置下攻击者可用大量单张购买灌出足够多的 range 撑爆 1M 回调上限，
///      使该期永久卡在 DRAWING、资金冻结（FR-C-24 禁止任何 rescue）。
///      修复：中奖人派生移出回调，改由 winnersOf 视图/事件离线还原（FR-C-16）。
contract LotteryCallbackGasTest is LotteryTestBase {
    uint32 private constant CALLBACK_LIMIT = 1_000_000;

    function _floodRanges(uint32 count) internal {
        // 每次单张购买产生一条 Range（FR-C-04），这是灌 range 的最廉价方式
        token.mint(alice, uint256(count) * PRICE);
        vm.startPrank(alice);
        token.approve(address(lottery), type(uint256).max);
        for (uint32 i = 0; i < count; i++) {
            lottery.buyTickets(1);
        }
        vm.stopPrank();
    }

    function _measureCallbackGas(uint32 roundId, uint256 seed) internal returns (uint256 used) {
        (uint256 requestId,) = lottery.vrfRequestOf(roundId);
        uint256[] memory words = new uint256[](1);
        words[0] = seed;
        uint256 before = gasleft();
        coordinator.fulfillRandomWordsWithOverride(requestId, address(lottery), words);
        used = before - gasleft();
    }

    /// @dev 少量 range 与大量 range 下，回调 gas 基本持平（不再随 range 数增长）
    function test_CallbackGasIndependentOfRangeCount() public {
        _buy(alice, 10); // 1 条 range
        _triggerDraw(1);
        uint256 gasFew = _measureCallbackGas(1, 42);

        uint32 r = lottery.s_currentRound();
        _floodRanges(2000); // 2000 条 range
        _triggerDraw(r);
        uint256 gasMany = _measureCallbackGas(r, 43);

        assertLt(gasFew, CALLBACK_LIMIT, "few ranges within budget");
        assertLt(gasMany, CALLBACK_LIMIT, "many ranges within budget");
        // 2000 倍 range 差异下，回调 gas 增幅应极小（仅事件里 ticketCount 变化）
        assertLt(gasMany, gasFew * 2, "callback gas must not scale with range count");
    }

    /// @dev 大量 range 下该期仍能正常结算并领奖（不会卡在 DRAWING）
    function test_HeavyRoundStillSettlesAndPays() public {
        _floodRanges(1500);
        _triggerDraw(1);
        uint256 used = _measureCallbackGas(1, 7);
        assertLt(used, CALLBACK_LIMIT, "settles within callback budget");
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.SETTLED));

        // 中奖人仍可由视图派生并正常领奖
        (, address[] memory winners,) = lottery.winnersOf(1);
        assertEq(winners[0], alice);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        lottery.claim(1, 0);
        assertGt(token.balanceOf(alice) - before, 0, "prize still claimable");
    }

    /// @dev 构造器用 slot 总数上限（<=16）把回调成本限死。
    ///      注意：这条测试此前叫「回调预算校验」，但 32 档配置实际撞的是 slots 闸，
    ///      两条路共用同一个 selector，给了那条（永远不触发的）预算校验虚假绿灯，
    ///      预算校验已因此移除（第四轮复查 M-4）
    function test_RevertWhen_TierSlotsExceedCap() public {
        // 32 档 × 1 名额 = 32 个 slot > 16
        uint16[] memory manyBps = new uint16[](32);
        uint8[] memory manyWinners = new uint8[](32);
        for (uint256 i = 0; i < 32; i++) {
            manyBps[i] = 312;
            manyWinners[i] = 1;
        }
        manyBps[0] = 10000 - 312 * 31;
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
            manyBps,
            manyWinners
        );
    }
}
