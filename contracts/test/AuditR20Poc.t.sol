// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @title 第 20 轮审计的可执行证据（PoC）
/// @notice **这些测试断言的是当前的（有缺陷的）行为**，不是期望行为。
///         它们的作用是把审计结论固定成可复现的事实；一旦对应问题被修复，
///         必须把这里的断言反转（而不是删掉测试）。
///         对应报告：`docs/audit/AUDIT-2026-08-11-R20.md`

/// @dev 只买票、不能收原生币的合约钱包（无 receive/fallback）
contract NonPayableBuyer {
    Lottery private immutable i_lottery;

    constructor(Lottery lottery_) {
        i_lottery = lottery_;
    }

    function buy(uint32 quantity) external payable {
        i_lottery.buyTickets{value: msg.value}(quantity);
    }

    function claim(uint32 roundId, uint8 tier) external {
        i_lottery.claim(roundId, tier);
    }
}

/// @dev 条件买入包装：只有本期还没人买票时才买，使「唯一买家」策略从 +EV 变成零风险
contract SoleBuyer {
    Lottery private immutable i_lottery;

    error NotSoleBuyer();

    constructor(Lottery lottery_) {
        i_lottery = lottery_;
    }

    function buyOnlyIfEmpty(uint32 roundId, uint32 batches, uint32 perBatch) external {
        (,,, uint32 ticketCount,,,,,) = i_lottery.getRound(roundId);
        if (ticketCount != 0) revert NotSoleBuyer();
        for (uint32 i = 0; i < batches; i++) {
            i_lottery.buyTickets{value: i_lottery.i_ticketPrice() * perBatch}(perBatch);
        }
    }

    function claim(uint32 roundId, uint8 tier) external {
        i_lottery.claim(roundId, tier);
    }

    receive() external payable {}
}

contract AuditR20PocTest is LotteryTestBase {
    // ===== H-1：VRF 订阅迁移把「防篡改闸」变成永久冻结闸 =====
    //
    // VRFCoordinatorV2_5.migrate(subId, newCoordinator) 由**订阅所有者**发起，会
    //   ① 在旧 coordinator 上 _deleteSubscription(subId)
    //   ② 以 coordinator 自己的身份对每个 consumer 调 setCoordinator(newCoordinator)
    //      （基类的 onlyOwnerOrCoordinator 允许 coordinator 调用）
    // 本合约曾把 coordinator 钉死为 immutable 以防 owner 换源操纵开奖（第一轮 Critical），
    // 但同一处防线把**合法迁移**也判成篡改：回调恒 revert，请求恒发往已删订阅的旧源。
    //
    // 【2026-08-13 已修复，SPEC Q9 方案 B】钉死已移除、随机源改为跟随 s_vrfCoordinator；
    // 换源杠杆改由 LotteryAdmin 从**权限侧**消除（owner 是一个物理上无法调
    // setCoordinator 的极小合约）。下面两个 PoC 的断言**已按修复后的语义反转**——
    // 这正是 R20 报告要求的「修复后需反转断言」，不是为了让测试变绿而改断言。

    /// @dev 【已反转】迁移后，已在 DRAWING 的期**能够正常结算**：真回调被接受
    function test_Poc_H1_MigrationNoLongerFreezesInFlightRound() public {
        _buy(alice, 100);
        assertEq(address(lottery).balance, 100 * PRICE);

        vm.warp(_drawTimeOf(1));
        lottery.performUpkeep("");
        (uint256 requestId,) = lottery.vrfRequestOf(1);
        assertGt(requestId, 0, "request must exist before migration");

        address newCoordinator = _simulateSubscriptionMigration();

        // 迁移后，新 coordinator 的回调被正常接受（此前会 revert CoordinatorTampered）
        uint256[] memory words = new uint256[](1);
        words[0] = 42;
        vm.prank(newCoordinator);
        lottery.rawFulfillRandomWords(requestId, words);

        // 该期正常结算，奖金可领——迁移不再意味着资金冻结
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.SETTLED), "settled across migration");
        assertGt(lottery.perWinnerAmount(1, 0), 0, "tier0 opened");

        (, address[] memory winners,) = lottery.winnersOf(1);
        uint256 before = winners[0].balance;
        vm.prank(winners[0]);
        lottery.claim(1, 0);
        assertGt(winners[0].balance, before, "prize actually paid out after migration");
    }

    /// @dev 【已反转】最坏情况下资金也不再被永久困住。
    ///      本测试里的「新随机源」是个无代码的测试替身，因此迁移后请求依然发不出去、
    ///      期仍会停在 DRAWING —— 这是刻意保留的最坏情形。修复前它意味着**永久冻结**
    ///      （FR-C-24 禁止任何取回路径）；现在有了 FR-C-29 的逃生通道，
    ///      30 天后任何人可作废该期，购票者按票款原路取回。
    ///      这正是 SPEC Q9 方案 C 的意义：它兜的是**任何原因**导致的卡死，
    ///      不依赖我们把失效模式列全
    function test_Poc_H1_StuckRoundsAreNoLongerPermanentlyFrozen() public {
        _simulateSubscriptionMigration();

        _buy(bob, 10);
        vm.warp(_drawTimeOf(1));
        lottery.performUpkeep("");
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.DRAWING));
        (uint256 reqId,) = lottery.vrfRequestOf(1);
        assertEq(reqId, 0, "worst case retained: request could not be made");

        // 30 天之内不得作废，防止有人拿它当提前退出的工具
        vm.expectRevert(Lottery.AbandonTooEarly.selector);
        lottery.abandonStuckRound(1);

        // 30 天后，任何人（这里用一个与本期毫无关系的地址）都可以作废
        vm.warp(_closeTimeOf(1) + lottery.SEAL_GAP() + lottery.ABANDON_TIMEOUT());
        vm.prank(carol);
        lottery.abandonStuckRound(1);
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.ABANDONED));

        // 购票者取回票款：票价 × 张数 − 该期抽成（1% 已在购票时分账，不退）
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        uint256 before = bob.balance;
        vm.prank(bob);
        lottery.refundAbandoned(1, idx);
        uint256 expected = 10 * PRICE - (10 * PRICE * FEE_BPS) / 10000;
        assertEq(bob.balance - before, expected, "refunded exactly the net ticket cost");

        // 退完之后该期账面归零，合约里只剩抽成——没有任何钱被困住
        (,,,, uint256 potAfter,,,,) = lottery.getRound(1);
        assertEq(potAfter, 0, "nothing left trapped in the abandoned round");
        // 抽成现在分处两个桶：s_accruedFees 与已记账未领的开奖奖励（FR-C-30）
        assertEq(
            address(lottery).balance,
            lottery.s_accruedFees() + lottery.s_pendingKeeperRewards(),
            "only fees (incl. accrued keeper rewards) remain"
        );
    }

    // ===== M-1：不能接收原生币的合约钱包，中奖后奖金永久领不出来 =====

    function test_Poc_M1_NonPayableWinnerCannotClaim() public {
        NonPayableBuyer wallet = new NonPayableBuyer(lottery);
        vm.deal(address(this), 1 ether);
        wallet.buy{value: PRICE * 10}(10); // 买光全场，必中一等奖

        _triggerDraw(1);
        _fulfill(1, 42);

        uint256[] memory pending = lottery.pendingPrizes(1, address(wallet));
        assertGt(pending[0], 0, "the contract wallet really is the tier-1 winner");

        // 界面显示「可领 594e12」，但领奖恒 revert；90 天后被 rolloverExpired 扫走
        vm.expectRevert(Lottery.TransferFailed.selector);
        wallet.claim(1, 0);
    }

    // ===== L-1：buyTickets 没有 roundId 闸，延迟上链会静默买进下一期 =====

    function test_Poc_L1_DelayedBuyLandsInNextRound() public {
        uint32 seen = lottery.s_currentRound();
        _buy(alice, 1);
        _triggerDraw(seen); // 开奖并立即开出下一期（FR-C-10）
        assertEq(lottery.s_currentRound(), seen + 1);

        // 用户以为在给 seen 期买票，交易晚了 SEAL_GAP 才上链
        _buy(bob, 5);
        assertEq(lottery.ticketsOwned(seen, bob), 0, "bob got nothing in the round he saw");
        assertEq(lottery.ticketsOwned(seen + 1, bob), 5, "bob silently bought into the next round");
    }

    // ===== H-2：FR-C-27 配比的资本门槛是**可循环使用**的 =====
    // SPEC 说「投 X 至多撬动 X 的 carry」，读起来像是要吃下整包 carry 就得备齐等额资本。
    // 实际上本金随中奖立刻回到攻击者手里，同一笔钱每期复用一次，
    // 每期净赚≈本金（只付 1% 抽成），整包 carry 会被逐期抽干。

    function test_Poc_H2_SoleBuyerRecyclesCapitalToDrainBuffer() public {
        _inject(carol, 1, 10 ether); // 运营方冷启动注资 10 ETH
        _triggerDraw(1); // 第 1 期零购票 → VOIDED，10 ETH 经缓冲释放进第 2 期
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.VOIDED));
        assertEq(_potOf(2), 10 ether);

        SoleBuyer attacker = new SoleBuyer(lottery);
        vm.deal(address(attacker), 1 ether);
        uint256 bankroll = address(attacker).balance;

        // 停售前最后一刻确认无人买票才买 1 ETH（1000 张 × 10 批）
        vm.warp(_closeTimeOf(2) - 1);
        attacker.buyOnlyIfEmpty(2, 10, 1000);
        _triggerDraw(2);
        _fulfill(2, 42);
        attacker.claim(2, 0);
        attacker.claim(2, 1);
        attacker.claim(2, 2);

        // 1 ETH 本金变成 1.98 ETH：净赚等额 carry 减去 1% 抽成，且零风险
        assertEq(address(attacker).balance, 1.98 ether);
        assertGt(address(attacker).balance, bankroll, "sole buyer profits risk-free");
        // 余下 9.01 ETH 留在缓冲，等着下一期用同一笔本金再抽一次
        assertEq(lottery.s_pendingPot() + lottery.s_pendingTier1(), 9.01 ether);
    }

    // ===== helper =====

    uint256 private constant DRAW_TIMEOUT_PLUS = 3 hours + 1;

    /// @dev 复现 VRFCoordinatorV2_5.migrate 对 consumer 的两个副作用
    function _simulateSubscriptionMigration() private returns (address newCoordinator) {
        newCoordinator = makeAddr("newVrfCoordinator");
        // ① 旧 coordinator 不再认这个 consumer（等效于 _deleteSubscription）
        coordinator.removeConsumer(subId, address(lottery));
        // ② 旧 coordinator 以自己的身份把 consumer 指向新源
        vm.prank(address(coordinator));
        lottery.setCoordinator(newCoordinator);
    }
}
