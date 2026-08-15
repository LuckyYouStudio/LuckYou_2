// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryKeeperReceiver} from "../src/cre/LotteryKeeperReceiver.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 只买票、不能收原生币的合约钱包（无 receive / fallback）
contract NonPayableBuyer {
    Lottery private immutable i_lottery;

    constructor(Lottery lottery) {
        i_lottery = lottery;
    }

    function buy(uint32 qty, uint256 price) external {
        uint32 _rid1 = i_lottery.s_currentRound();
        i_lottery.buyTickets{value: price * qty}(qty, _rid1);
    }

    function refund(uint32 roundId, uint256 idx) external {
        i_lottery.refundAbandoned(roundId, _one(idx));
    }

    function refundTo(uint32 roundId, uint256 idx, address to) external {
        i_lottery.refundAbandonedTo(roundId, _one(idx), to);
    }

    function _one(uint256 idx) private pure returns (uint256[] memory idxs) {
        idxs = new uint256[](1);
        idxs[0] = idx;
    }

    // 刻意没有 receive / fallback —— 这正是 R20 M-1 里那类合约钱包
}

/// @dev 第 22~50 轮审计的四个发现（A-1 ~ A-4）的可执行回归。
///      每条都先复现「缺陷本来的样子」，再断言修复后的行为。
contract AuditR50PocTest is LotteryTestBase {
    // ===== A-1：withdrawFees 曾可零成本抹掉开奖奖励（FR-C-30 被架空）=====

    /// @dev 缺陷原貌：`withdrawFees` 无权限、约 3 万 gas，且**全额**清空
    ///      `s_accruedFees`；而 `_accrueKeeperReward` 的第三道夹逼是
    ///      「不超过当下实际尚存的 accruedFees」。任何人只需在封盘期
    ///      （停售 → 开奖之间的 75 分钟，此时抽成不会再增加）调一次，
    ///      本期开奖奖励就恒为 0 —— 无需抢跑、无需竞速。
    ///      修复：`withdrawFees` 为当期预留一份奖励额度。
    function test_WithdrawFeesCannotZeroTheKeeperReward() public {
        _buy(alice, 500); // 足够大的期，奖励本应打满上限（= 一张票价）
        vm.warp(_drawTimeOf(1));
        assertEq(
            lottery.pendingKeeperReward(1),
            PRICE,
            "precondition: this round should earn the full reward"
        );

        uint256 accrued = lottery.s_accruedFees();
        uint256 withdrawable = lottery.withdrawableFees();
        assertEq(withdrawable, accrued - PRICE, "reserve equals the pending reward");

        vm.prank(bob);
        lottery.withdrawFees();
        assertEq(treasury.balance, withdrawable, "treasury still gets everything but the reserve");
        assertEq(lottery.s_accruedFees(), PRICE, "the reserve stays behind");
        assertEq(lottery.pendingKeeperReward(1), PRICE, "reward survives the sweep");

        vm.prank(carol);
        lottery.performUpkeep("");
        assertEq(lottery.keeperRewardOf(carol), PRICE, "the keeper is actually paid");

        // 预留只是延后、不是沉淀：该期开出后立刻可提
        assertEq(lottery.withdrawableFees(), 0, "reserve consumed by the payout");
    }

    /// @dev 预留额永远够付：奖励 = 该期抽成的 20%，故留存必然覆盖实发额。
    ///      任意购票量下断言「提费后仍能足额发放」
    function testFuzz_ReserveAlwaysCoversTheActualPayout(uint32 qty) public {
        qty = uint32(bound(qty, 1, 1000));
        _buy(alice, qty);
        vm.warp(_drawTimeOf(1));

        uint256 due = lottery.pendingKeeperReward(1);
        // 预留不得把提费通道堵死：奖励恒为该期抽成的 20%（还要再夹一次票价上限），
        // 故只要有抽成，可提额就严格大于 0 —— withdrawFees 永远不会变成不可用
        assertGt(lottery.s_accruedFees(), 0);
        assertGt(lottery.withdrawableFees(), 0, "the reserve must never brick fee withdrawal");
        lottery.withdrawFees();

        vm.prank(carol);
        lottery.performUpkeep("");
        assertEq(lottery.keeperRewardOf(carol), due, "payout must not shrink after a fee sweep");
    }

    /// @dev 预留不得把抽成永久卡死：零票的期不预留任何东西
    function test_EmptyRoundReservesNothing() public {
        _buy(alice, 100);
        vm.warp(_drawTimeOf(1));
        lottery.performUpkeep(""); // 第 1 期开奖，第 2 期开出且零票

        uint256 accrued = lottery.s_accruedFees();
        assertGt(accrued, 0);
        assertEq(lottery.withdrawableFees(), accrued, "an empty round reserves nothing");
        lottery.withdrawFees();
        assertEq(lottery.s_accruedFees(), 0);
    }

    // ===== A-2：作废期的退款曾没有 claimTo 那样的收款地址出口 =====

    /// @dev 缺陷原貌：R20 M-1 为「无 receive 的合约钱包中奖即弃奖」加了 `claimTo`，
    ///      但其后新增的 FR-C-29 退款通道重新引入了同一个缺陷 ——
    ///      `refundAbandoned` 只能付给 `msg.sender`。而退款**没有**
    ///      `rolloverExpired` 那样的过期兜底，那笔钱会永久留在该期 `pot` 里。
    ///      修复：`refundAbandonedTo`。
    function test_ContractBuyerCanRecoverViaRefundAbandonedTo() public {
        NonPayableBuyer buyer = new NonPayableBuyer(lottery);
        vm.deal(address(buyer), 10 ether);
        buyer.buy(10, PRICE);

        _stallAndAbandon(1);
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.ABANDONED));
        uint256 owed = _potOf(1);
        assertGt(owed, 0, "precondition: the round owes a refund");

        // 直付仍然失败 —— 那是事实，对方确实收不了款
        vm.expectRevert(Lottery.TransferFailed.selector);
        buyer.refund(1, 0);

        // 但现在有出路：指定一个能收款的地址
        address hot = makeAddr("hotWallet");
        buyer.refundTo(1, 0, hot);
        assertEq(hot.balance, owed, "refund lands on the chosen address");
        assertEq(_potOf(1), 0, "the round owes nothing more");
        assertTrue(lottery.rangeRefunded(1, 0));
    }

    /// @dev `refundAbandonedTo` 不得增加任何权限面：不持有该 Range 的人
    ///      指定任何 `to` 都拿不到钱
    function test_RevertWhen_RefundAbandonedToCalledByNonOwner() public {
        _buy(alice, 10);
        _stallAndAbandon(1);

        uint256[] memory idxs = new uint256[](1);
        idxs[0] = 0;
        vm.prank(bob);
        vm.expectRevert(Lottery.NotRangeOwner.selector);
        lottery.refundAbandonedTo(1, idxs, bob);
    }

    function test_RevertWhen_RefundAbandonedToZeroAddress() public {
        _buy(alice, 10);
        _stallAndAbandon(1);

        uint256[] memory idxs = new uint256[](1);
        idxs[0] = 0;
        vm.prank(alice);
        vm.expectRevert(Lottery.InvalidRecipient.selector);
        lottery.refundAbandonedTo(1, idxs, address(0));
    }

    // ===== A-3：CRE 桥接器触发开奖 ⇒ 奖励曾永久锁死 =====

    /// @dev 缺陷原貌：SPEC Q8 把 keeper 迁到 CRE，链上落点 `LotteryKeeperReceiver`
    ///      转调 `performUpkeep`，于是 `msg.sender` 是**桥接器合约**，
    ///      FR-C-30 的奖励记在它名下。而初版桥接器既没有领取路径、也没有
    ///      `receive`：每一期最多一张票价的运营抽成被永久烧进一个取不出的余额，
    ///      `s_pendingKeeperRewards` 单调增长成一笔无法清偿的负债。
    ///      修复：桥接器加 `sweepKeeperReward` + `receive`；彩票侧加
    ///      `claimKeeperRewardTo` 供其它合约 keeper 使用。
    function test_CreReceiverCanSweepItsKeeperReward() public {
        address beneficiary = makeAddr("keeperBeneficiary");
        LotteryKeeperReceiver receiver =
            new LotteryKeeperReceiver(makeAddr("forwarder"), address(lottery), beneficiary);

        _buy(alice, 500);
        vm.warp(_drawTimeOf(1));
        vm.prank(makeAddr("forwarder"));
        receiver.onReport("", abi.encode(true));

        uint256 earned = lottery.keeperRewardOf(address(receiver));
        assertEq(earned, PRICE, "the reward is booked to the bridge");

        // 无权限：谁来按都一样，钱只会流向构造时钉死的受益人
        vm.prank(bob);
        receiver.sweepKeeperReward();

        assertEq(beneficiary.balance, earned, "reward reaches the beneficiary");
        assertEq(lottery.keeperRewardOf(address(receiver)), 0);
        assertEq(lottery.s_pendingKeeperRewards(), 0, "no unpayable liability left behind");
        assertEq(address(receiver).balance, 0, "nothing sediments in the bridge");
    }

    function test_RevertWhen_SweepingAnEmptyBridge() public {
        LotteryKeeperReceiver receiver = new LotteryKeeperReceiver(
            makeAddr("forwarder"), address(lottery), makeAddr("keeperBeneficiary")
        );
        vm.expectRevert(LotteryKeeperReceiver.NothingToSweep.selector);
        receiver.sweepKeeperReward();
    }

    /// @dev 合约 keeper 的通用出路：彩票侧的 `claimKeeperRewardTo`
    function test_ClaimKeeperRewardToPaysAChosenAddress() public {
        _buy(alice, 500);
        vm.warp(_drawTimeOf(1));
        vm.prank(bob);
        lottery.performUpkeep("");

        address hot = makeAddr("hotWallet");
        vm.prank(bob);
        lottery.claimKeeperRewardTo(hot);
        assertEq(hot.balance, PRICE);
        assertEq(lottery.keeperRewardOf(bob), 0);
        assertEq(lottery.s_pendingKeeperRewards(), 0);
    }

    function test_RevertWhen_ClaimKeeperRewardToZeroAddress() public {
        _buy(alice, 500);
        vm.warp(_drawTimeOf(1));
        vm.prank(bob);
        lottery.performUpkeep("");

        vm.prank(bob);
        vm.expectRevert(Lottery.InvalidRecipient.selector);
        lottery.claimKeeperRewardTo(address(0));
    }

    // ===== A-4：构造器曾只挡「远古锚点」，没挡「远未来锚点」=====

    /// @dev 缺陷原貌：R20 L-4 加了 `anchorTime + 365 days >= now` 挡住追赶循环 OOG，
    ///      但对称的那一侧无人看守。锚点若落在未来，第 1 期 closeTime 就落在未来，
    ///      `performUpkeep` 永远不到期、期号永不推进 —— 而 `buyTickets` 只看
    ///      state 与 closeTime，实例会**照常收钱**。日程无 setter、FR-C-24 又禁止
    ///      任何救援手段，这种实例只能作废重部。
    function test_RevertWhen_AnchorIsInTheFuture() public {
        vm.expectRevert(Lottery.InvalidSchedule.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            PRICE,
            uint64(block.timestamp + 1),
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
    }

    /// @dev 边界：锚点 == 当前时刻是合法的（Deploy.s.sol 的快节奏分支就取这个值）
    function test_AnchorAtExactlyNowIsAccepted() public {
        Lottery ok = new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            PRICE,
            uint64(block.timestamp),
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
        (, uint64 closeTime,,,,,,,) = ok.getRound(1);
        assertGt(closeTime, block.timestamp);
    }

    // ===== helper =====

    /// @dev 让某期卡死到可作废（VRF 请求失败 ⇒ 停在 DRAWING ⇒ 过 ABANDON_TIMEOUT）
    function _stallAndAbandon(uint32 roundId) internal {
        coordinator.removeConsumer(subId, address(lottery));
        vm.warp(_drawTimeOf(roundId));
        lottery.performUpkeep("");
        coordinator.addConsumer(subId, address(lottery));

        vm.warp(uint256(_closeTimeOf(roundId)) + lottery.SEAL_GAP() + lottery.ABANDON_TIMEOUT());
        lottery.abandonStuckRound(roundId);
    }
}
