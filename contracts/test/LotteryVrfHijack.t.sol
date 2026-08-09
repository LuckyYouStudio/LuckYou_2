// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

interface IRawFulfill {
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external;
}

/// @dev 攻击者控制的假 coordinator：请求返回固定 id，并可用任意种子主动回调
contract EvilCoordinator {
    uint256 public constant REQUEST_ID = 777;

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata)
        external
        pure
        returns (uint256)
    {
        return REQUEST_ID;
    }

    function fulfill(address consumer, uint256 seed) external {
        uint256[] memory words = new uint256[](1);
        words[0] = seed;
        IRawFulfill(consumer).rawFulfillRandomWords(REQUEST_ID, words);
    }
}

/// @dev 安全回归（2026-08-09 审计发现 #1，Critical）：
///      基类 VRFConsumerBaseV2Plus 暴露了 owner 可调、非 virtual（无法 override）的
///      setCoordinator。若不设防，owner 可把随机源换成自控合约，离线暴力挑选种子
///      使自己的票中一等奖，从而合法赢走他人投入的奖池——推翻 FR-C-11/22/24。
///      修复：coordinator 构造时钉死；请求只发往钉死地址，回调强制校验随机源未被替换。
contract LotteryVrfHijackTest is LotteryTestBase {
    /// @dev 核心回归：即使 owner 换掉随机源，假 coordinator 也无法操纵开奖结果
    function test_RevertWhen_HijackedCoordinatorFulfills() public {
        _buy(alice, 50);
        _buy(bob, 49);
        _buy(address(this), 1); // address(this) 是 owner，持有 99 号票
        (,,, uint32 ticketCount,,,,,) = lottery.getRound(1);

        EvilCoordinator evil = new EvilCoordinator();
        lottery.setCoordinator(address(evil)); // 基类函数无法封禁，调用仍会成功

        vm.warp(_drawTimeOf(1));
        lottery.performUpkeep("");

        // 离线挑选能让 99 号票中一等奖的种子
        uint256 chosenSeed;
        for (uint256 s = 1; s < 100_000; s++) {
            if (uint256(keccak256(abi.encode(s, uint256(0)))) % ticketCount == 99) {
                chosenSeed = s;
                break;
            }
        }
        assertGt(chosenSeed, 0, "seed search failed");

        // 攻击被拦截：随机源已非构造时钉死的那一个
        vm.expectRevert(Lottery.CoordinatorTampered.selector);
        evil.fulfill(address(lottery), chosenSeed);

        // 该期未被污染，奖池分文未动
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.DRAWING));
        assertEq(lottery.perWinnerAmount(1, 0), 0);
        assertEq(token.balanceOf(address(lottery)), 100e6);
    }

    /// @dev 请求恒发往钉死的 coordinator：换源后真 coordinator 仍能正常回调结算
    function test_RequestsAlwaysGoToPinnedCoordinator() public {
        _buy(alice, 10);
        EvilCoordinator evil = new EvilCoordinator();
        lottery.setCoordinator(address(evil));

        vm.warp(_drawTimeOf(1));
        lottery.performUpkeep("");

        // 请求落在真 coordinator 上，可被真 coordinator 履约
        (uint256 requestId,) = lottery.vrfRequestOf(1);
        assertGt(requestId, 0);
        assertTrue(requestId != evil.REQUEST_ID(), "request must not come from evil coordinator");

        // 恢复随机源后正常结算，结果来自真 VRF
        lottery.setCoordinator(address(coordinator));
        _fulfill(1, 42);
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.SETTLED));
    }

    /// @dev 未被篡改时一切照常
    function test_NormalFlowUnaffected() public {
        _buy(alice, 10);
        _settleRound(1, 42);
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.SETTLED));
        assertEq(lottery.perWinnerAmount(1, 0), 594e4);
    }
}
