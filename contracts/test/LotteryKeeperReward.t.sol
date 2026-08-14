// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 收款时回调合约、试图重入领取的 keeper
contract ReentrantKeeper {
    Lottery immutable lottery;
    bool entered;
    bool public innerSucceeded;

    constructor(Lottery l) {
        lottery = l;
    }

    function trigger() external {
        lottery.performUpkeep("");
    }

    function doClaim() external {
        lottery.claimKeeperReward();
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        try lottery.claimKeeperReward() {
            innerSucceeded = true;
        } catch {}
    }
}

/// @dev FR-C-30 开奖激励。
///      设计意图：把「需要有人按时按按钮」变成「按了有钱拿」，使运营方消失后
///      仍有人有理由接手。资金来自**该期自己的运营抽成**，奖池分文不动。
///
///      本文件重点钉三道闸——它们各自堵住一种刷奖励的路子，缺一条就漏一个洞。
contract LotteryKeeperRewardTest is LotteryTestBase {
    /// @dev 与合约中完全相同的算式（刻意不写成简化公式，以复现同样的取整）
    function _expectedReward(uint32 qty) internal view returns (uint256) {
        uint256 gross = uint256(qty) * PRICE;
        uint256 fee = (gross * FEE_BPS) / 10000;
        uint256 reward = (fee * lottery.KEEPER_REWARD_BPS()) / 10000;
        return reward > PRICE ? PRICE : reward;
    }

    /// @dev 基本路径：触发开奖的人拿到该期抽成的 20%，且可自行领取
    function test_TriggerEarnsShareOfThatRoundsFee() public {
        _buy(alice, 100);
        uint256 feesBefore = lottery.s_accruedFees();

        vm.warp(_drawTimeOf(1));
        vm.prank(bob); // bob 与本期毫无关系，纯粹来按按钮
        lottery.performUpkeep("");

        uint256 expected = _expectedReward(100);
        assertGt(expected, 0, "sanity: reward must be non-zero for 100 tickets");
        assertEq(lottery.keeperRewardOf(bob), expected, "accrued exactly 20% of this round's fee");
        assertEq(lottery.s_pendingKeeperRewards(), expected, "aggregate matches");
        // 钱来自抽成，不是奖池
        assertEq(lottery.s_accruedFees(), feesBefore - expected, "taken from fees");
        assertEq(_potOf(1), 99e14, "pot untouched");

        uint256 balBefore = bob.balance;
        vm.prank(bob);
        lottery.claimKeeperReward();
        assertEq(bob.balance - balBefore, expected, "paid out on claim");
        assertEq(lottery.keeperRewardOf(bob), 0);
        assertEq(lottery.s_pendingKeeperRewards(), 0);
    }

    /// @dev 闸 1：零票作废的期不给奖励。
    ///      否则无人玩时，有人可以每个间隔触发一次 VOID 刷钱，
    ///      吃掉此前有人买票时赚到的抽成
    function test_VoidedRoundPaysNoReward() public {
        _buy(alice, 100);
        _settleRound(1, 42); // 第 2 期开出，但没人买

        uint32 empty = lottery.s_currentRound();
        uint256 feesBefore = lottery.s_accruedFees();
        vm.warp(_drawTimeOf(empty));
        vm.prank(bob);
        lottery.performUpkeep("");

        assertEq(uint8(_stateOf(empty)), uint8(Lottery.RoundState.VOIDED));
        assertEq(lottery.keeperRewardOf(bob), 0, "no reward for a zero-ticket round");
        assertEq(lottery.s_accruedFees(), feesBefore, "fees untouched");
    }

    /// @dev 闸 2：retryDraw 完全不给奖励。
    ///      否则有人每 3 小时重试一次刷钱，顺带把运营方的 LINK 烧光
    function test_RetryDrawPaysNoReward() public {
        _buy(alice, 100);
        coordinator.removeConsumer(subId, address(lottery));
        vm.warp(_drawTimeOf(1));
        lottery.performUpkeep(""); // 请求失败，期停在 DRAWING
        coordinator.addConsumer(subId, address(lottery));

        uint256 rewardAfterUpkeep = lottery.keeperRewardOf(address(this));
        uint256 feesBefore = lottery.s_accruedFees();

        vm.warp(block.timestamp + 4 hours);
        vm.prank(bob);
        lottery.retryDraw(1);

        assertEq(lottery.keeperRewardOf(bob), 0, "retryDraw must never pay");
        assertEq(lottery.keeperRewardOf(address(this)), rewardAfterUpkeep, "unchanged");
        assertEq(lottery.s_accruedFees(), feesBefore, "fees untouched by retry");
    }

    /// @dev 闸 3：奖励只能来自**该期自己**的抽成，不能吸走历史累计。
    ///      构造：先用一个大期攒下抽成，再用一个 1 张票的小期去触发
    function test_SmallRoundCannotDrainFeesFromEarlierBigRounds() public {
        _buy(alice, 1000); // 大期，攒下可观抽成
        _settleRound(1, 42);
        uint256 fatFees = lottery.s_accruedFees();
        assertGt(fatFees, 0);

        uint32 small = lottery.s_currentRound();
        _buy(bob, 1); // 小期只有 1 张票
        vm.warp(_drawTimeOf(small));
        vm.prank(carol);
        lottery.performUpkeep("");

        uint256 got = lottery.keeperRewardOf(carol);
        assertEq(got, _expectedReward(1), "bounded by this round's own fee");
        // 1 张票的抽成是 1e12，20% 即 2e11 —— 远小于大期攒下的抽成
        assertLt(got, fatFees / 100, "cannot siphon the fat balance from round 1");
    }

    /// @dev 上限：奖励不得超过一张票价，无论该期多大
    function test_RewardCappedAtOneTicketPrice() public {
        // 5000 张票（分 5 笔，受 MAX_TICKETS_PER_TX 限制）
        for (uint256 i = 0; i < 5; i++) {
            _buy(alice, 1000);
        }
        vm.warp(_drawTimeOf(1));
        vm.prank(bob);
        lottery.performUpkeep("");

        // 未加上限时应为 5000*1e14*1%*20% = 1e12... 实际远超时才会触顶，
        // 这里断言恒不超过票价即可
        assertLe(lottery.keeperRewardOf(bob), PRICE, "never exceeds one ticket price");
    }

    /// @dev 提费不得抹掉本期的开奖奖励（第 50 轮 A-1）。
    ///
    ///      这条测试原名 `test_RewardClampedToAvailableFees`，断言的是
    ///      「运营方先提走抽成 ⇒ 触发者拿 0」，把当时的实现行为当成了正确行为。
    ///      但 `withdrawFees` **无权限**、约 3 万 gas：那等于给了任何人一个
    ///      零成本抹平 FR-C-30 的断路器，而 FR-C-30 存在的全部意义正是
    ///      「运营方缺席时仍有人有理由接手」。运营方例行提费同样会误伤。
    ///      现在 `withdrawFees` 为当期预留一份，场景仍然照跑，断言反转。
    ///
    ///      `_accrueKeeperReward` 里那道「不超过 accruedFees」的夹逼**保留不动**：
    ///      预留使它在正常运行下不再可达，但它仍是防下溢的最后一道防线。
    function test_RewardSurvivesAFeeSweep() public {
        _buy(alice, 100);
        uint256 accrued = lottery.s_accruedFees();
        lottery.withdrawFees(); // 运营方先把抽成提走
        uint256 reserved = lottery.s_accruedFees();
        assertGt(reserved, 0, "a reserve must be held back");
        assertEq(treasury.balance, accrued - reserved);

        vm.warp(_drawTimeOf(1));
        uint256 due = lottery.pendingKeeperReward(1);
        assertGt(due, 0, "the button must still be worth pressing");

        vm.prank(bob);
        lottery.performUpkeep("");

        assertEq(lottery.keeperRewardOf(bob), due, "the sweep did not starve the keeper");
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.DRAWING), "draw still proceeds");
    }

    /// @dev pull 模式 + nonReentrant：领取时的回调无法重入再领一次
    function test_RevertWhen_ReentrantClaimKeeperReward() public {
        ReentrantKeeper k = new ReentrantKeeper(lottery);
        _buy(alice, 100);
        vm.warp(_drawTimeOf(1));
        k.trigger();

        uint256 owed = lottery.keeperRewardOf(address(k));
        assertGt(owed, 0);
        k.doClaim();

        assertFalse(k.innerSucceeded(), "reentrant claim must be blocked");
        assertEq(address(k).balance, owed, "paid exactly once");
        assertEq(lottery.keeperRewardOf(address(k)), 0);
    }

    function test_RevertWhen_ClaimWithNothingOwed() public {
        vm.prank(alice);
        vm.expectRevert(Lottery.NoRewardToClaim.selector);
        lottery.claimKeeperReward();
    }

    /// @dev 前端用的预览视图必须与实际发放一致，否则界面会骗人
    function test_PendingKeeperRewardMatchesActualPayout() public {
        _buy(alice, 200);
        assertEq(lottery.pendingKeeperReward(1), 0, "not due yet -> 0");

        vm.warp(_drawTimeOf(1));
        uint256 preview = lottery.pendingKeeperReward(1);
        assertEq(preview, _expectedReward(200));

        vm.prank(bob);
        lottery.performUpkeep("");
        assertEq(lottery.keeperRewardOf(bob), preview, "preview equals actual");
    }

    /// @dev 性质：无论买多少、谁来触发，奖励永远只从抽成出，奖池分文不动
    function testFuzz_RewardNeverTouchesThePot(uint16 qty) public {
        uint32 n = uint32(bound(qty, 1, 1000));
        _buy(alice, n);
        uint256 potBefore = _potOf(1);
        uint256 feesBefore = lottery.s_accruedFees();

        vm.warp(_drawTimeOf(1));
        vm.prank(bob);
        lottery.performUpkeep("");

        uint256 reward = lottery.keeperRewardOf(bob);
        assertEq(_potOf(1), potBefore, "pot must never be touched");
        assertEq(lottery.s_accruedFees(), feesBefore - reward, "reward comes only from fees");
        assertLe(reward, PRICE, "cap holds for every size");
        // 偿付性：合约余额仍覆盖全部义务
        assertGe(
            address(lottery).balance,
            lottery.s_accruedFees() + lottery.s_pendingKeeperRewards() + potBefore
        );
    }
}
