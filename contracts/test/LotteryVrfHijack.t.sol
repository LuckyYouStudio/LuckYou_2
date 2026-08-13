// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {Lottery} from "../src/Lottery.sol";
import {LotteryAdmin} from "../src/LotteryAdmin.sol";
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

/// @dev 安全回归：换随机源这条杠杆（首轮 Critical）。
///
///      **防线换过一次位置，这里记录原委，避免后人误以为保护被删掉了。**
///
///      基类 `VRFConsumerBaseV2Plus.setCoordinator` 的修饰符是
///      `onlyOwnerOrCoordinator` 且非 virtual（无法 override 封禁）。
///      若不设防，owner 可把随机源换成自控合约、离线暴力挑选种子稳中头奖。
///
///      · 旧方案（首轮～2026-08-13）：把 coordinator 钉死为 immutable，回调校验随机源未变。
///        被 R20 审计 H-1 打穿——**该校验把 Chainlink 官方订阅迁移也判成篡改**
///        （`migrate` 会以 coordinator 身份替每个 consumer 调 `setCoordinator`），
///        迁移后回调恒失败、请求又发往已删订阅的旧源，全部奖池永久冻结。
///
///      · 现方案（SPEC Q9 方案 B）：钉死移除，随机源跟随 `s_vrfCoordinator`；
///        杠杆改从**权限侧**消除——Lottery 的 owner 是 `LotteryAdmin`，
///        一个在字节码层面就没有能力发出 `setCoordinator` 调用的极小合约。
///        于是 `onlyOwnerOrCoordinator` 的两个分支里只剩「合法迁移」一条路。
contract LotteryVrfHijackTest is LotteryTestBase {
    /// @dev 核心回归：owner 交给 LotteryAdmin 后，换源这条路在**权限层**就走不通
    function test_AdminOwnerCannotSwapCoordinator() public {
        LotteryAdmin admin = new LotteryAdmin(address(lottery), address(this));
        lottery.transferOwnership(address(admin));
        admin.acceptLotteryOwnership();
        assertEq(lottery.owner(), address(admin), "lottery is owned by the admin contract");

        EvilCoordinator evil = new EvilCoordinator();

        // 原 owner（本测试合约）已不是 owner，直接调被基类拒绝
        vm.expectRevert();
        lottery.setCoordinator(address(evil));

        // 而 LotteryAdmin 根本没有任何函数能发出这个调用——它的接口里就没有 setCoordinator。
        // 下面这句证明的是「该选择器在 admin 上不存在」，而不是「调用失败了」
        (bool ok,) =
            address(admin).call(abi.encodeWithSignature("setCoordinator(address)", address(evil)));
        assertFalse(ok, "LotteryAdmin must expose no path to setCoordinator");

        // 随机源仍是真的那一个，开奖照常
        assertEq(address(lottery.s_vrfCoordinator()), address(coordinator));
        _buy(alice, 10);
        _settleRound(1, 42);
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.SETTLED));
    }

    /// @dev LotteryAdmin 只转发 FR-C-22 的三项业务权限，且不转发 Lottery 的所有权
    function test_AdminForwardsOnlyTheThreeBusinessPowers() public {
        LotteryAdmin admin = new LotteryAdmin(address(lottery), address(this));
        lottery.transferOwnership(address(admin));
        admin.acceptLotteryOwnership();

        admin.setFeeBps(250);
        assertEq(lottery.s_feeBps(), 250, "setFeeBps forwarded");
        admin.setTreasury(bob);
        assertEq(lottery.s_treasury(), bob, "setTreasury forwarded");
        admin.setSalesPaused(true);
        assertTrue(lottery.s_salesPaused(), "setSalesPaused forwarded");

        // 不得存在把 Lottery 所有权交出去的路径——有它就能把所有权换回 EOA，
        // 本合约的全部意义随之归零
        (bool ok,) = address(admin)
            .call(abi.encodeWithSignature("transferLotteryOwnership(address)", address(this)));
        assertFalse(ok, "must expose no path to hand the lottery back to an EOA");
        // 通用执行入口同理
        (ok,) = address(admin)
            .call(abi.encodeWithSignature("execute(address,bytes)", address(lottery), bytes("")));
        assertFalse(ok, "must expose no generic execute");
    }

    /// @dev 非 owner 动不了 admin
    function test_RevertWhen_NonOwnerUsesAdmin() public {
        LotteryAdmin admin = new LotteryAdmin(address(lottery), address(this));
        vm.prank(alice);
        vm.expectRevert(LotteryAdmin.NotOwner.selector);
        admin.setFeeBps(500);
    }

    /// @dev **如实记录残余风险**：若运营方没做这一步、owner 仍是 EOA，
    ///      换源攻击依然成立。这不是回归失败，而是本方案的前提条件——
    ///      保护来自「owner 是 LotteryAdmin」这个部署事实，而非合约内的校验。
    ///      部署清单必须包含移交所有权这一步（FR-D-02）
    function test_ResidualRisk_EoaOwnerCanStillSwapCoordinator() public {
        // 刻意不移交所有权，owner 保持为 EOA（本测试合约）
        _buy(alice, 50);
        _buy(bob, 49);
        _buy(address(this), 1); // owner 持有 99 号票
        (,,, uint32 ticketCount,,,,,) = lottery.getRound(1);

        EvilCoordinator evil = new EvilCoordinator();
        lottery.setCoordinator(address(evil)); // EOA owner 可以换源

        vm.warp(_drawTimeOf(1));
        lottery.performUpkeep("");

        uint256 chosenSeed;
        for (uint256 s = 1; s < 100_000; s++) {
            if (uint256(keccak256(abi.encode(s, uint256(0)))) % ticketCount == 99) {
                chosenSeed = s;
                break;
            }
        }
        assertGt(chosenSeed, 0, "seed search failed");
        evil.fulfill(address(lottery), chosenSeed);

        // 攻击成立：owner 用挑好的种子让自己那张票中了一等奖
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.SETTLED));
        (, address[] memory winners,) = lottery.winnersOf(1);
        assertEq(winners[0], address(this), "EOA owner ground the seed and won tier-1");
    }

    /// @dev 未被篡改时一切照常
    function test_NormalFlowUnaffected() public {
        _buy(alice, 10);
        _settleRound(1, 42);
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.SETTLED));
        assertEq(lottery.perWinnerAmount(1, 0), 594e12);
    }
}
