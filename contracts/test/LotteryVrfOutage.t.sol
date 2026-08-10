// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 安全回归（2026-08-10 第十轮红队 #1）：VRF 不可用不得让整台机器停摆。
///      此前 performUpkeep 里的 VRF 请求失败会让整笔交易回滚，连 _openNextRound 一起失败
///      → 期号永不推进 → 全部资金（含缓冲区）永久冻结，而 FR-C-24 禁止任何救援手段。
///      隔离后最坏只是本期卡在 DRAWING（可 retryDraw），彩票继续运转。
contract LotteryVrfOutageTest is LotteryTestBase {
    /// @dev 订阅被移除 consumer 后：本期卡住，但下一期照常开出、照常可购票
    function test_VrfOutageDoesNotBrickTheContract() public {
        _buy(alice, 10);

        // 模拟订阅侧把本合约摘掉（VRF 请求会 revert InvalidConsumer）
        coordinator.removeConsumer(subId, address(lottery));

        vm.warp(_drawTimeOf(1));
        vm.expectEmit(true, false, false, false);
        emit Lottery.DrawRequestFailed(1);
        lottery.performUpkeep(""); // 不再整笔回滚

        // 本期停在 DRAWING，等待 retryDraw
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.DRAWING));
        (uint256 requestId,) = lottery.vrfRequestOf(1);
        assertEq(requestId, 0, "no request was registered");

        // 关键：下一期照常开出，彩票继续运转
        uint32 next = lottery.s_currentRound();
        assertEq(next, 2, "next round opened despite VRF outage");
        assertEq(uint8(_stateOf(next)), uint8(Lottery.RoundState.OPEN));

        token.mint(bob, 5e6);
        vm.startPrank(bob);
        token.approve(address(lottery), 5e6);
        lottery.buyTickets(5); // 新期可正常购票
        vm.stopPrank();
        assertEq(lottery.ticketsOwned(next, bob), 5);
    }

    /// @dev VRF 恢复后，卡住的期可由任何人 retryDraw 救回并正常结算领奖
    function test_StuckRoundRecoversAfterVrfRestored() public {
        _buy(alice, 10);
        coordinator.removeConsumer(subId, address(lottery));
        vm.warp(_drawTimeOf(1));
        lottery.performUpkeep("");
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.DRAWING));

        // 订阅侧恢复
        coordinator.addConsumer(subId, address(lottery));

        vm.warp(block.timestamp + 3 hours);
        vm.prank(bob); // 任何人可救
        lottery.retryDraw(1);
        _fulfill(1, 42);

        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.SETTLED));
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        lottery.claim(1, 0);
        assertGt(token.balanceOf(alice) - before, 0, "funds recovered, prize paid");
    }

    /// @dev 自调用包装不得被外部直接调用
    function test_RevertWhen_ExternalCallsRequestWrapper() public {
        vm.expectRevert(Lottery.OnlySelf.selector);
        lottery.requestRandomWordsSelf();
    }
}
