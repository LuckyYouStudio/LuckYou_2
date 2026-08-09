// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryKeeperReceiver} from "../src/cre/LotteryKeeperReceiver.sol";
import {ReceiverTemplate} from "../src/cre/ReceiverTemplate.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev CRE 桥接接收器：只有 forwarder 能投递报告，报告为真时转调 performUpkeep
contract LotteryKeeperReceiverTest is LotteryTestBase {
    LotteryKeeperReceiver internal receiver;
    address internal forwarder = makeAddr("forwarder");

    function setUp() public override {
        super.setUp();
        receiver = new LotteryKeeperReceiver(forwarder, address(lottery));
    }

    function test_OnReport_TriggersDrawWhenDue() public {
        _buy(alice, 10);
        vm.warp(_drawTimeOf(1));

        vm.prank(forwarder);
        receiver.onReport("", abi.encode(true));

        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.DRAWING));
        assertEq(lottery.s_currentRound(), 2);
    }

    function test_RevertWhen_NonForwarderCalls() public {
        _buy(alice, 1);
        vm.warp(_drawTimeOf(1));

        vm.expectRevert(
            abi.encodeWithSelector(ReceiverTemplate.InvalidSender.selector, address(this), forwarder)
        );
        receiver.onReport("", abi.encode(true));
    }

    function test_RevertWhen_ReportSaysDoNotExecute() public {
        vm.prank(forwarder);
        vm.expectRevert(LotteryKeeperReceiver.ExecutionNotRequested.selector);
        receiver.onReport("", abi.encode(false));
    }

    function test_OnReport_RevertsWhenDrawNotDue() public {
        _buy(alice, 1);
        // 未到开奖时刻：performUpkeep 会 revert，报告投递整体失败（CRE 端可见）
        vm.prank(forwarder);
        vm.expectRevert(Lottery.DrawNotDue.selector);
        receiver.onReport("", abi.encode(true));
    }
}
