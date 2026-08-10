// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 安全回归（2026-08-10 第四轮自查）：缓冲释放按窗口完整度**打折**，而非 0/1 门。
///      0/1 门（要求窗口达 80% 才释放）会在 keeper 持续不及时时让缓冲永远出不来——
///      与「阶跃参与度门槛导致永久冻结」是同一个坑。此处锁定打折语义：
///      压缩窗口只等比例削减本期可释放额度，绝不把资金卡死。
contract LotteryWindowProRataTest is LotteryTestBase {
    function _buffer() internal view returns (uint256) {
        return lottery.s_pendingPot() + lottery.s_pendingTier1();
    }

    /// @dev 核心回归：keeper 每期都不及时，缓冲仍持续释放（不冻结）
    function test_BufferDrainsEvenWithPersistentlyLateKeeper() public {
        _buy(alice, 3); // 三等奖不开出 → 产生 carry
        _settleRound(1, 7);
        uint256 start = _buffer();
        assertGt(start, 0, "buffer seeded");

        uint32 r = lottery.s_currentRound();
        uint256 prev = start;
        for (uint256 i = 0; i < 5; i++) {
            _buy(bob, 10);
            // 每期都拖到临近下一场次才开期（窗口被压到接近下限）
            uint64 nextSlot = _closeTimeOf(r) + 2 days;
            vm.warp(uint256(nextSlot) - 31 minutes);
            lottery.performUpkeep("");
            _fulfill(r, 100 + i);
            uint256 now_ = _buffer();
            assertLt(now_, prev, "buffer must keep draining despite late keeper");
            prev = now_;
            r = lottery.s_currentRound();
        }
        // 每期按窗口比例打折释放，5 期累计释放可观比例（关键是单调下降，已由循环断言）
        assertLt(prev, (start * 4) / 5, "a meaningful share is released over several rounds");
    }

    /// @dev 及时开期时全额释放（正常运行不打折）
    function test_TimelyOpenReleasesFullBuffer() public {
        _buy(alice, 3);
        _settleRound(1, 7);
        assertGt(_buffer(), 0);

        uint32 r = lottery.s_currentRound();
        _buy(bob, 10);
        _settleRound(r, 42); // drawTime 一到就触发 = 及时
        assertEq(_buffer(), 0, "timely open releases everything");
    }

    /// @dev 压缩窗口会等比例削减本期可释放额度（削弱择时独占的收益）
    function test_ShortWindowReleasesProportionallyLess() public {
        _buy(alice, 3);
        _settleRound(1, 7);
        uint256 seeded = _buffer();

        uint32 r = lottery.s_currentRound();
        _buy(bob, 10);
        // 拖到只剩约 1/4 名义窗口
        uint64 nextSlot = _closeTimeOf(r) + 2 days;
        uint64 prevDraw = _closeTimeOf(r) + 75 minutes;
        uint256 nominal = uint256(nextSlot) - prevDraw;
        vm.warp(uint256(nextSlot) - nominal / 4);
        lottery.performUpkeep("");
        _fulfill(r, 42);

        uint256 released = seeded - _buffer();
        assertGt(released, 0, "still releases something");
        assertLt(released, seeded / 2, "but much less than a timely open would");
    }
}
