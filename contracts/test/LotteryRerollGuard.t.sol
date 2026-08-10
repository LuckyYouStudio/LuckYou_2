// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 安全回归（2026-08-10 审计发现 B，Medium）：
///      retryDraw 覆写 r.vrfRequestId 曾使旧请求的回调即使在 DRAWING 期到达也被作废，
///      从而任何人可在超时后抢先 retryDraw 作废一个即将落地、对己不利的结果 = 重摇。
///      修复：fulfillRandomWords 改为先到先得——DRAWING 期内任何已登记请求的回调先落定；
///      SETTLED 后由 state 闸拦下所有迟到回调（FR-C-15 仍满足）。
contract LotteryRerollGuardTest is LotteryTestBase {
    /// @dev 核心回归：retryDraw 后，先到达的旧回调仍能正常结算，无法被作废重摇
    function test_OldCallbackStillSettlesAfterRetry() public {
        _buy(alice, 50);
        _buy(bob, 50);
        _triggerDraw(1);
        (uint256 oldRequest,) = lottery.vrfRequestOf(1);

        vm.warp(block.timestamp + 3 hours);
        vm.prank(bob);
        lottery.retryDraw(1); // 覆写 vrfRequestId，但旧请求仍在真 coordinator 处挂着

        // 旧回调到达：先到先得，直接结算，不被作废
        uint256[] memory words = new uint256[](1);
        words[0] = 12345;
        coordinator.fulfillRandomWordsWithOverride(oldRequest, address(lottery), words);

        assertEq(
            uint8(_stateOf(1)), uint8(Lottery.RoundState.SETTLED), "old callback settles the round"
        );
        (,,,,,, uint256 seed,,) = lottery.getRound(1);
        assertEq(seed, 12345, "result comes from whichever callback arrived first");
    }

    /// @dev 结算后迟到的回调（无论新旧请求）都被 state 闸拦下，不改写已定结果（FR-C-15）
    function test_LateCallbackCannotOverwriteSettled() public {
        _buy(alice, 10);
        _triggerDraw(1);
        (uint256 firstRequest,) = lottery.vrfRequestOf(1);

        vm.warp(block.timestamp + 3 hours);
        lottery.retryDraw(1);
        (uint256 secondRequest,) = lottery.vrfRequestOf(1);

        // 第二个请求先落地并结算
        uint256[] memory words = new uint256[](1);
        words[0] = 999;
        coordinator.fulfillRandomWordsWithOverride(secondRequest, address(lottery), words);
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.SETTLED));
        (,,,,,, uint256 settledSeed,,) = lottery.getRound(1);

        // 第一个请求的回调迟到：被拒，结果不变
        words[0] = 111;
        coordinator.fulfillRandomWordsWithOverride(firstRequest, address(lottery), words);
        (,,,,,, uint256 seedAfter,,) = lottery.getRound(1);
        assertEq(seedAfter, settledSeed, "settled result is immutable");
    }

    /// @dev retryDraw 的合法用途（VRF 真卡死）不受影响
    function test_RetryStillWorksWhenVrfStuck() public {
        _buy(alice, 10);
        _triggerDraw(1);

        vm.warp(block.timestamp + 3 hours);
        lottery.retryDraw(1); // 第一次请求假设永不回调
        _fulfill(1, 42); // 新请求正常回调
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.SETTLED));
    }
}
