// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 安全回归（2026-08-10 审计发现 A，High）：
///      过期滚存 rolloverExpired 与未开出奖级的 carry 曾直接注入 s_currentRound，
///      绕过 injectPot 的封盘时间闸。攻击者可在封盘期（票已冻结）确认自己是唯一买家后
///      调 rolloverExpired 把整包过期奖金砸进本期、必中全奖级、确定性独占。
///      修复：carry 先入 s_pendingPot/s_pendingTier1 缓冲区，由 _openNextRound
///      在开出拥有完整未封盘售票窗口的新期时消费——钱只能进无人能预先卡位的期。
contract LotteryCarryTimingTest is LotteryTestBase {
    /// @dev 核心回归：封盘期调 rolloverExpired 不会改变当前期奖池，钱入缓冲区
    function test_RolloverExpiredDoesNotFundSealedRound() public {
        _buy(alice, 10);
        _settleRound(1, 42); // 第 1 期无人领，90 天后可滚存

        vm.warp(_closeTimeOf(1) + 91 days);
        lottery.performUpkeep(""); // 第 2 期作废，第 3 期开出
        uint32 attackRound = lottery.s_currentRound();

        _buy(bob, 8); // 攻击者独占 8 张票
        vm.warp(_closeTimeOf(attackRound)); // 封盘期

        uint256 potBefore = _potOf(attackRound);
        vm.prank(bob);
        lottery.rolloverExpired(1);

        // 修复后：当前（封盘）期奖池分文未增，过期奖金进缓冲区
        assertEq(_potOf(attackRound), potBefore, "sealed round pot must not change");
        assertEq(lottery.s_pendingPot(), 99e13, "expired prize buffered, not injected");

        // 该期照常开奖：bob 只赢到自己 8 张票对应的原始奖池，拿不到过期奖金
        _settleRound(attackRound, 7);
        uint256 before = bob.balance;
        vm.startPrank(bob);
        lottery.claim(attackRound, 0);
        lottery.claim(attackRound, 1);
        lottery.claim(attackRound, 2);
        vm.stopPrank();
        uint256 won = bob.balance - before;
        assertEq(won, 792e12, "bob only wins the round's own 8-ticket pot, not the expired prize");
    }

    /// @dev 缓冲的过期奖金在下一新期开出时并入其 pot（有完整售票窗口，无法卡位）
    function test_BufferedCarryReleasedIntoFreshRound() public {
        _buy(alice, 10);
        _settleRound(1, 42);
        vm.warp(_closeTimeOf(1) + 91 days);
        lottery.performUpkeep("");
        uint32 r = lottery.s_currentRound();

        vm.prank(carol);
        lottery.rolloverExpired(1);
        assertEq(lottery.s_pendingPot(), 99e13);

        // 推进到下一新期：缓冲清空，钱进入新期 pot，且新期此刻仍在完整售票窗口内
        _buy(alice, 1); // 让 r 非空，正常开奖推进
        _settleRound(r, 1);
        uint32 fresh = lottery.s_currentRound();
        assertEq(lottery.s_pendingPot(), 0, "buffer consumed");
        assertGe(_potOf(fresh), 99e13, "expired prize now in fresh round pot");
        assertGt(_closeTimeOf(fresh), uint64(block.timestamp), "fresh round still selling");
    }

    /// @dev 未开出奖级的 carry（Q1）同样先入缓冲、并入下一新期一等奖份额
    function test_UnopenedTierCarryBuffered() public {
        _buy(alice, 3); // 三等奖（5 名）不开出，其 15% carry
        _settleRound(1, 7);
        assertEq(_carryOf(2), 0, "carry not injected into current round directly");
        assertEq(lottery.s_pendingTier1(), 44550000000000, "unopened-tier carry buffered");

        // 下一新期开出时并入其一等奖份额
        _buy(bob, 10);
        _settleRound(2, 8);
        assertEq(lottery.s_pendingTier1(), 0, "buffer consumed");
        // R21 审计指出这里原本是**空断言**：断言未结算期的 perWinnerAmount 等于 0，
        // 而未结算期它恒为 0，等于什么都没验。真正该验的是 carry 确实落进了
        // round3 的一等奖份额（tier1Carry），下面这句才有意义
        assertEq(_carryOf(3), 44550000000000, "buffered carry landed in round3 tier-1 share");
        assertEq(uint8(_stateOf(3)), uint8(Lottery.RoundState.OPEN), "round3 is the fresh round");
    }

    /// @dev injectPot 与 rolloverExpired 现在时间语义一致：都不改变已封盘期的奖池
    function test_InjectAndRolloverConsistentTimeGate() public {
        _buy(alice, 10);
        _settleRound(1, 42);
        vm.warp(_closeTimeOf(1) + 91 days);
        lottery.performUpkeep("");
        uint32 r = lottery.s_currentRound();
        vm.warp(_closeTimeOf(r)); // 封盘期

        // injectPot 直接 revert（#5）
        vm.deal(alice, alice.balance + (1e14));
        vm.startPrank(alice);
        vm.expectRevert(Lottery.SalesClosed.selector);
        lottery.injectPot{value: 1e14}(r);
        vm.stopPrank();

        // rolloverExpired 不 revert 但也不影响本期（钱入缓冲）
        vm.prank(alice);
        lottery.rolloverExpired(1);
        assertEq(_potOf(r), 0, "rollover cannot fund the sealed round either");
    }
}
