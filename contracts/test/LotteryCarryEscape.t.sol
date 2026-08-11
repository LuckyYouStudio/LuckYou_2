// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 安全回归（2026-08-10 第四轮审计）：滚存/注资资金的释放规则（FR-C-27）。
///      演进过程（三个方案，前两个都被 PoC 打穿，此处锁定第三个）：
///      ① 阶跃门槛「票数达 100 就全放」→ 恰好买 100 张即可独占整包，成本 O(1)；
///      ② 加「连续扣留 3 期后强制放行」逃生阀 → 攻击者用 1 张票攒计数器，
///         成本降到 0.0008 ETH 吃掉 1 ETH（审计第四轮 Critical）；
///      ③ 现行：按自售额配比释放 + 要求售票窗口完整度，资本门槛与捕获量线性挂钩，
///         且只要有人买票就会释放对应额度，不会永久冻结。
contract LotteryCarryEscapeTest is LotteryTestBase {
    function _distributedIn(uint32 roundId) internal view returns (uint256 dist) {
        uint8[3] memory counts = [1, 2, 5];
        for (uint8 t = 0; t < 3; t++) {
            uint256 per = lottery.perWinnerAmount(roundId, t);
            if (per > 0) dist += per * counts[t];
        }
    }

    /// @dev 核心回归：小额买家无法撬动大额 carry——能拿到的至多等于自己的自售额
    function test_SmallBuyerCannotCaptureLargeCarry() public {
        vm.deal(carol, carol.balance + (10_000e14));
        vm.startPrank(carol);
        lottery.injectPot{value: 10_000e14}(1); // 一大笔注资
        vm.stopPrank();

        _buy(bob, 8); // 自售净额仅 7.92e14 wei
        _settleRound(1, 7);

        // 可分配的 carry 至多等于自售额，其余退回缓冲
        uint256 distributed = _distributedIn(1);
        assertLe(distributed, 792e12 * 2, "capture bounded by own stake");
        assertGe(lottery.s_pendingPot(), 9_900e14, "the rest stays buffered");

        // 单期捕获量被自售额锁住：拿回的至多是「本金 + 等额 carry」，
        // 而不是整包 10000。想拿更多就必须投更多（资本门槛线性挂钩）
        uint256 before = bob.balance;
        vm.startPrank(bob);
        lottery.claim(1, 0);
        lottery.claim(1, 1);
        lottery.claim(1, 2);
        vm.stopPrank();
        uint256 got = bob.balance - before;
        assertLe(got, 8e14 * 2, "single-round capture bounded by own stake");
        assertLt(got, 100e14, "cannot drain the large carry with 8 tickets");
    }

    /// @dev 想拿走多少 carry 就得自掏相应票款（资本门槛与捕获量线性挂钩）
    function test_CaptureRequiresProportionalStake() public {
        _inject(carol, 1, 500e14);

        _buy(alice, 600); // 自售净额 594 >= 注资 500，足以全额解锁
        _settleRound(1, 7);

        assertEq(lottery.s_pendingPot(), 0, "carry fully released when stake matches");
        assertEq(_distributedIn(1), 594e14 + 500e14, "whole pot distributed");
    }

    /// @dev 低参与度不会造成永久冻结：每期都按自售额释放一部分
    function test_CarryDrainsGraduallyNotFrozen() public {
        _inject(carol, 1, 100e14);

        _buy(bob, 20);
        _settleRound(1, 7);
        uint256 buffered = lottery.s_pendingPot();
        assertGt(buffered, 0, "part withheld");

        // 后续期持续有人买票 → 缓冲持续减少，不会卡死
        uint32 r = lottery.s_currentRound();
        for (uint256 i = 0; i < 6; i++) {
            _buy(bob, 20);
            _settleRound(r, 100 + i);
            r = lottery.s_currentRound();
        }
        assertLt(lottery.s_pendingPot(), buffered, "buffer drains over time, never frozen");
    }

    /// @dev 结算后 getRound().pot 不再报告已被扣留的钱（账面与实际一致）
    function test_RoundPotReflectsWithheldCarry() public {
        _inject(carol, 1, 900e14);

        _buy(bob, 8);
        assertEq(_potOf(1), 900e14 + 792e12, "pot includes injection before settlement");

        _settleRound(1, 7);
        assertLt(_potOf(1), 900e14, "withheld carry removed from round pot");
        assertEq(lottery.carriedPotOf(1), _potOf(1) - 792e12, "carriedPot reduced accordingly");
    }
}
