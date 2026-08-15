// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 针对第二/三轮新增逻辑（缓冲区、参与度门槛、暂停快照）的性质测试，
///      让 fuzz 自己去找边界反例，而不是只测我想得到的场景
contract LotteryCarryFuzzTest is LotteryTestBase {
    /// @dev 性质：任何购票量下，结算前后「合约债务总额」守恒——
    ///      分配出去的 + 退回缓冲的 == 本期 pot + 承接的 tier1Carry
    function testFuzz_SettlementConservesValue(uint32 qty, uint256 seed) public {
        qty = uint32(bound(qty, 1, 500));

        // 先制造一笔滚存进缓冲：第 1 期开奖后无人领，过期滚存
        _buy(alice, 3); // 票数少 → 三等奖不开出 → 必产生 carry
        _settleRound(1, 7);

        uint256 bufferBefore = lottery.s_pendingPot() + lottery.s_pendingTier1();
        uint32 r = lottery.s_currentRound();

        _buy(bob, qty);
        uint256 potBefore = _potOf(r);
        uint256 carryInBefore = _carryOf(r);

        _settleRound(r, seed);

        // 时序：performUpkeep 先开出下一期（消费掉 bufferBefore），
        // 再由 fulfillRandomWords 结算本期（新 carry 入缓冲）。故结算后：
        //   本期已分配 + 本期新入缓冲 == 本期 pot + 本期承接的 tier1Carry
        uint256 distributed = 0;
        uint8[3] memory counts = [1, 2, 5];
        (,,, uint32 ticketCount,,,,,) = lottery.getRound(r);
        for (uint8 t = 0; t < 3; t++) {
            uint256 per = lottery.perWinnerAmount(r, t);
            if (per > 0) distributed += per * counts[t];
        }
        uint256 bufferAfter = lottery.s_pendingPot() + lottery.s_pendingTier1();
        assertEq(distributed + bufferAfter, potBefore + carryInBefore, "settlement conserves value");
        assertLe(distributed, potBefore + carryInBefore, "cannot distribute more than available");
        assertGt(ticketCount, 0);

        // 旧缓冲没有蒸发：它已流入结算瞬间开出的那一期
        uint32 next = lottery.s_currentRound();
        assertEq(
            _potOf(next) + _carryOf(next), bufferBefore, "old buffer released into the next round"
        );
    }

    /// @dev 性质：门槛未达标时，carriedPot 与 tier1Carry 必须原样退回缓冲，一分不少
    function testFuzz_ExcessCarryWithheldExactly(uint32 qty, uint256 injectAmt) public {
        qty = uint32(bound(qty, 1, 50)); // 自售额远小于注资额，必定触发扣留
        injectAmt = bound(injectAmt, 100e14, 1_000_000e14); // 远大于自售额

        _inject(carol, 1, injectAmt);

        _buy(bob, qty);
        uint256 carried = lottery.carriedPotOf(1);
        assertEq(carried, injectAmt, "injection fully counted as carried");

        _settleRound(1, 42);

        // 超出自售额配比的部分退回缓冲
        uint256 selfSold = uint256(qty) * PRICE * (10000 - FEE_BPS) / 10000;
        uint256 expectedWithheld = injectAmt > selfSold ? injectAmt - selfSold : 0;
        assertEq(lottery.s_pendingPot(), expectedWithheld, "withheld exactly the excess");
        // 分配的只可能来自自售部分
        uint256 organic = uint256(qty) * PRICE * (10000 - FEE_BPS) / 10000;
        uint256 distributed = 0;
        uint8[3] memory counts = [1, 2, 5];
        for (uint8 t = 0; t < 3; t++) {
            uint256 per = lottery.perWinnerAmount(1, t);
            if (per > 0) distributed += per * counts[t];
        }
        assertLe(
            distributed,
            organic * (1 + lottery.CARRY_MATCH_MULTIPLIER()),
            "capture bounded by stake x multiplier"
        );
    }

    /// @dev 性质：无论何时触发开奖，新期售票窗口恒 >= MIN_SALES_WINDOW
    function testFuzz_SalesWindowAlwaysAboveFloor(uint256 delay) public {
        _buy(alice, 1);
        uint64 drawTime = _drawTimeOf(1);
        // 攻击者在开奖时刻之后的任意时点触发（模拟 keeper 任意缺席时长）
        delay = bound(delay, 0, 30 days);
        vm.warp(uint256(drawTime) + delay);

        lottery.performUpkeep("");
        uint32 r = lottery.s_currentRound();
        uint64 window = _closeTimeOf(r) - uint64(block.timestamp);
        assertGe(window, lottery.MIN_SALES_WINDOW(), "window floor holds at any trigger time");
    }

    /// @dev 性质：暂停快照对任意购票时点一致——同一期内暂停状态不会中途改变可购性
    function testFuzz_PauseSnapshotStableWithinRound(bool pauseMid, uint32 qty) public {
        qty = uint32(bound(qty, 1, 50));
        bool openable = lottery.salesOpenFor(1);
        assertTrue(openable, "round 1 opened unpaused");

        if (pauseMid) lottery.setSalesPaused(true);

        // 无论中途怎么切换，本期始终可购
        vm.deal(bob, bob.balance + (uint256(qty) * PRICE));
        uint32 _rid1 = lottery.s_currentRound();
        vm.startPrank(bob);
        lottery.buyTickets{value: PRICE * qty}(qty, _rid1);
        vm.stopPrank();
        assertEq(lottery.ticketsOwned(1, bob), qty);
        assertEq(lottery.salesOpenFor(1), openable, "snapshot never changes mid-round");
    }
}
