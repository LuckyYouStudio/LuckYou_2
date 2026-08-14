// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    VRFCoordinatorV2_5Mock
} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Lottery} from "../src/Lottery.sol";

/// @dev 共享测试基座：VRF mock + 原生 ETH 计价 + 默认参数的 Lottery
contract LotteryTestBase is Test {
    uint64 internal constant ANCHOR = 1_700_000_000;
    uint256 internal constant PRICE = 0.0001 ether; // 1e14 wei（FR-C-01）
    uint16 internal constant FEE_BPS = 100; // 1%

    VRFCoordinatorV2_5Mock internal coordinator;
    Lottery internal lottery;
    uint256 internal subId;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal treasury = makeAddr("treasury");

    function setUp() public virtual {
        vm.warp(ANCHOR + 1);
        coordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        subId = coordinator.createSubscription();
        coordinator.fundSubscription(subId, 1000 ether);
        lottery = _deployLottery();
        coordinator.addConsumer(subId, address(lottery));
        vm.deal(address(this), 10_000 ether);
    }

    function _deployLottery() internal returns (Lottery) {
        return new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            PRICE,
            ANCHOR,
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
    }

    function _intervals() internal pure returns (uint32[] memory a) {
        a = new uint32[](3);
        a[0] = 2 days;
        a[1] = 3 days;
        a[2] = 2 days;
    }

    function _tierBps() internal pure returns (uint16[] memory a) {
        a = new uint16[](3);
        a[0] = 6000;
        a[1] = 2500;
        a[2] = 1500;
    }

    function _tierWinners() internal pure returns (uint8[] memory a) {
        a = new uint8[](3);
        a[0] = 1;
        a[1] = 2;
        a[2] = 5;
    }

    function _buy(address user, uint32 qty) internal {
        uint256 cost = PRICE * qty;
        vm.deal(user, user.balance + cost);
        vm.prank(user);
        lottery.buyTickets{value: cost}(qty);
    }

    /// @dev 原生币注资
    function _inject(address from, uint32 roundId, uint256 amount) internal {
        vm.deal(from, from.balance + amount);
        vm.prank(from);
        lottery.injectPot{value: amount}(roundId);
    }

    function _closeTimeOf(uint32 roundId) internal view returns (uint64 closeTime) {
        (, closeTime,,,,,,,) = lottery.getRound(roundId);
    }

    function _drawTimeOf(uint32 roundId) internal view returns (uint64 drawTime) {
        (,, drawTime,,,,,,) = lottery.getRound(roundId);
    }

    function _stateOf(uint32 roundId) internal view returns (Lottery.RoundState state) {
        (state,,,,,,,,) = lottery.getRound(roundId);
    }

    function _potOf(uint32 roundId) internal view returns (uint256 pot) {
        (,,,, pot,,,,) = lottery.getRound(roundId);
    }

    function _carryOf(uint32 roundId) internal view returns (uint256 carry) {
        (,,,,, carry,,,) = lottery.getRound(roundId);
    }

    /// @dev 结算时刻（领奖窗口自此起算，审计第四轮）
    function _settledAtOf(uint32 roundId) internal view returns (uint64 settledAt) {
        (settledAt,) = lottery.claimDeadlineOf(roundId);
    }

    /// @dev 快进到开奖时刻并触发 performUpkeep
    function _triggerDraw(uint32 roundId) internal {
        vm.warp(_drawTimeOf(roundId));
        lottery.performUpkeep("");
    }

    /// @dev 用指定种子完成 VRF 回调
    function _fulfill(uint32 roundId, uint256 seed) internal {
        (uint256 requestId,) = lottery.vrfRequestOf(roundId);
        uint256[] memory words = new uint256[](1);
        words[0] = seed;
        coordinator.fulfillRandomWordsWithOverride(requestId, address(lottery), words);
    }

    function _settleRound(uint32 roundId, uint256 seed) internal {
        _triggerDraw(roundId);
        _fulfill(roundId, seed);
    }

    /// @dev 线性扫描对照实现（用于 fuzz 验证二分查找）
    function _linearOwnerOf(uint32 roundId, uint32 ticketId) internal view returns (address) {
        Lottery.TicketRange[] memory ranges = lottery.getRanges(roundId, 0, type(uint256).max);
        for (uint256 i = 0; i < ranges.length; i++) {
            if (ticketId >= ranges[i].start && ticketId < ranges[i].end) {
                return ranges[i].owner;
            }
        }
        return address(0);
    }
}

contract LotteryConstructorTest is LotteryTestBase {
    function test_ConstructorOpensRoundOne() public view {
        assertEq(lottery.s_currentRound(), 1);
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.OPEN));
        // 锚点 + 第一个间隔（2 天）
        assertEq(_closeTimeOf(1), ANCHOR + 2 days);
        assertEq(_drawTimeOf(1), ANCHOR + 2 days + 75 minutes);
    }

    function test_RevertWhen_FeeAboveCap() public {
        vm.expectRevert(Lottery.FeeTooHigh.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            PRICE,
            ANCHOR,
            _intervals(),
            treasury,
            1001,
            _tierBps(),
            _tierWinners()
        );
    }

    function test_RevertWhen_TierBpsSumWrong() public {
        uint16[] memory badBps = _tierBps();
        badBps[0] = 5999;
        vm.expectRevert(Lottery.InvalidTierConfig.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            PRICE,
            ANCHOR,
            _intervals(),
            treasury,
            FEE_BPS,
            badBps,
            _tierWinners()
        );
    }

    function test_RevertWhen_IntervalNotLongerThanSealGap() public {
        uint32[] memory badIntervals = new uint32[](1);
        badIntervals[0] = 75 minutes;
        vm.expectRevert(Lottery.InvalidSchedule.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            PRICE,
            ANCHOR,
            badIntervals,
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
    }
}

contract LotteryBuyTest is LotteryTestBase {
    function test_BuyTickets_AccountingSplitsPotAndFee() public {
        _buy(alice, 100);
        // 100 张 × 0.0001 ETH，1% 抽成
        assertEq(_potOf(1), 99e14, "pot");
        assertEq(lottery.s_accruedFees(), 1e14, "fees");
        assertEq(address(lottery).balance, 100e14, "balance");
        Lottery.TicketRange[] memory ranges = lottery.getRanges(1, 0, type(uint256).max);
        assertEq(ranges.length, 1);
        assertEq(ranges[0].start, 0);
        assertEq(ranges[0].end, 100);
        assertEq(ranges[0].owner, alice);
        assertEq(lottery.ticketsOwned(1, alice), 100);
    }

    function test_BuyTickets_SecondBuyAppendsRange() public {
        _buy(alice, 10);
        _buy(bob, 5);
        _buy(alice, 3); // Q3：同址多次购票，产生多个 Range
        Lottery.TicketRange[] memory ranges = lottery.getRanges(1, 0, type(uint256).max);
        assertEq(ranges.length, 3);
        assertEq(ranges[1].start, 10);
        assertEq(ranges[1].end, 15);
        assertEq(ranges[2].start, 15);
        assertEq(ranges[2].end, 18);
        assertEq(lottery.ticketsOwned(1, alice), 13);
    }

    function test_RevertWhen_BuyAtOrAfterCloseTime() public {
        vm.warp(_closeTimeOf(1)); // FR-C-09：即使 keeper 未触发也拒绝
        vm.deal(alice, alice.balance + (PRICE));
        vm.startPrank(alice);
        vm.expectRevert(Lottery.SalesClosed.selector);
        lottery.buyTickets{value: PRICE * 1}(1);
        vm.stopPrank();
    }

    /// @dev 暂停在「下一期开出时」生效（快照语义，审计第三轮 #1）。
    ///      对已开出的期无效的回归见 LotteryFieldControl.t.sol
    function test_RevertWhen_BuyWhilePaused() public {
        lottery.setSalesPaused(true);
        _buy(alice, 1); // 第 1 期开期时未暂停，仍可购票
        _settleRound(1, 42); // 开出第 2 期时快照 paused=true

        vm.deal(bob, bob.balance + (PRICE));
        vm.startPrank(bob);
        vm.expectRevert(Lottery.SalesArePaused.selector);
        lottery.buyTickets{value: PRICE * 1}(1);
        vm.stopPrank();
    }

    function test_RevertWhen_BuyZeroOrOverMax() public {
        vm.deal(alice, alice.balance + (PRICE * 2000));
        vm.startPrank(alice);
        vm.expectRevert(Lottery.InvalidQuantity.selector);
        lottery.buyTickets{value: PRICE * 0}(0);
        vm.expectRevert(Lottery.ExceedsMaxPerTx.selector);
        lottery.buyTickets{value: PRICE * 1001}(1001); // FR-C-06
        vm.stopPrank();
    }

    /// @dev FR-C-04 验收：批量购买 gas 亚线性
    function test_Gas_Buy100LessThan3xBuy10() public {
        _buy(carol, 1); // 预热存储槽

        vm.deal(alice, alice.balance + (PRICE * 110));
        vm.startPrank(alice);
        uint256 g0 = gasleft();
        lottery.buyTickets{value: PRICE * 10}(10);
        uint256 gas10 = g0 - gasleft();
        g0 = gasleft();
        lottery.buyTickets{value: PRICE * 100}(100);
        uint256 gas100 = g0 - gasleft();
        vm.stopPrank();

        assertLt(gas100, gas10 * 3, "buy(100) gas must be < 3x buy(10)");
    }

    /// @dev FR-C-05 验收：任意 ticketId 二分结果 == 线性扫描
    function testFuzz_OwnerOfTicketMatchesLinearScan(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        uint256 buys = 1 + (seed % 15);
        for (uint256 i = 0; i < buys; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _buy(users[r % 3], uint32(1 + (r % 50)));
        }
        (,,, uint32 ticketCount,,,,,) = lottery.getRound(1);
        uint32 ticketId = uint32(uint256(keccak256(abi.encode(seed, "pick"))) % ticketCount);
        assertEq(lottery.ownerOfTicket(1, ticketId), _linearOwnerOf(1, ticketId));
    }

    function test_RevertWhen_TicketOutOfRange() public {
        _buy(alice, 10);
        vm.expectRevert(Lottery.TicketOutOfRange.selector);
        lottery.ownerOfTicket(1, 10);
    }

    function test_InjectPot_AddsToPotWithoutFee() public {
        _inject(alice, 1, 50e14);
        assertEq(_potOf(1), 50e14);
        assertEq(lottery.s_accruedFees(), 0); // FR-C-26 验收：注资不抽成
    }

    function test_RevertWhen_InjectNotOpenRound() public {
        _buy(alice, 1);
        _triggerDraw(1); // round1 进入 DRAWING
        vm.deal(alice, alice.balance + (1e14));
        vm.startPrank(alice);
        vm.expectRevert(Lottery.RoundNotOpen.selector);
        lottery.injectPot{value: 1e14}(1);
        vm.stopPrank();
    }
}

contract LotteryDrawTest is LotteryTestBase {
    function test_CheckUpkeep_OnlyAfterDrawTime() public {
        _buy(alice, 1);
        (bool needed,) = lottery.checkUpkeep("");
        assertFalse(needed);
        vm.warp(_closeTimeOf(1)); // 封盘期内也不触发
        (needed,) = lottery.checkUpkeep("");
        assertFalse(needed);
        vm.warp(_drawTimeOf(1));
        (needed,) = lottery.checkUpkeep("");
        assertTrue(needed);
    }

    function test_RevertWhen_PerformUpkeepBeforeDrawTime() public {
        _buy(alice, 1);
        vm.warp(_closeTimeOf(1)); // 已停售但未到开奖时刻
        vm.expectRevert(Lottery.DrawNotDue.selector);
        lottery.performUpkeep("");
    }

    /// @dev FR-C-10 验收：发起 VRF 后 currentRound 已 +1 且新期可购票
    function test_PerformUpkeep_OpensNextRoundImmediately() public {
        _buy(alice, 10);
        _triggerDraw(1);
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.DRAWING));
        assertEq(lottery.s_currentRound(), 2);
        assertEq(uint8(_stateOf(2)), uint8(Lottery.RoundState.OPEN));
        _buy(bob, 5); // 新期立即可购票
        assertEq(lottery.ticketsOwned(2, bob), 5);
    }

    /// @dev FR-C-08：空期作废，不消耗 VRF 请求
    function test_EmptyRound_VoidedWithoutVrf() public {
        vm.warp(_drawTimeOf(1));
        vm.expectEmit(true, false, false, true);
        emit Lottery.RoundVoided(1);
        lottery.performUpkeep("");
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.VOIDED));
        (uint256 requestId,) = lottery.vrfRequestOf(1);
        assertEq(requestId, 0, "voided round must not request VRF");
        assertEq(lottery.s_currentRound(), 2);
    }

    /// @dev FR-C-26：VOIDED 期的注资经缓冲区转出（第四轮修复：不再直接注入下期，
    ///      否则可被「让期空转 + 压缩窗口时触发 VOID」绕过按窗口打折的释放规则）
    function test_VoidedRound_InjectionRollsToNextPot() public {
        _inject(alice, 1, 50e14);

        vm.warp(_drawTimeOf(1));
        // toRound 恒为 0：进缓冲时去向未定，真正去向由 CarryReleased 给出
        vm.expectEmit(true, true, false, true);
        emit Lottery.PrizeRolledOver(1, 0, 50e14);
        lottery.performUpkeep("");

        // 及时触发 → 缓冲全额释放进新开出的第 2 期
        assertEq(_potOf(2), 50e14, "released into round 2");
        assertEq(lottery.s_pendingPot(), 0, "buffer drained");
    }

    /// @dev Q2：极端延迟时跳过已错过的场次，closeTime 永远在未来且落在日程网格上
    function test_Schedule_SkipsMissedSlots() public {
        _buy(alice, 1);
        // 日程网格（锚点起）：+2d, +5d, +7d, +9d, +12d, ...
        vm.warp(ANCHOR + 10 days);
        lottery.performUpkeep("");
        assertEq(_closeTimeOf(2), ANCHOR + 12 days);
    }

    function test_RetryDraw_RevertBeforeTimeout_NewRequestAfter() public {
        _buy(alice, 10);
        _triggerDraw(1);
        (uint256 oldRequest,) = lottery.vrfRequestOf(1);

        vm.warp(block.timestamp + 3 hours - 1);
        vm.expectRevert(Lottery.RetryTooEarly.selector);
        lottery.retryDraw(1);

        vm.warp(block.timestamp + 1);
        vm.prank(bob); // FR-C-14：任何人可调用
        lottery.retryDraw(1);
        (uint256 newRequest,) = lottery.vrfRequestOf(1);
        assertTrue(newRequest != oldRequest);
    }

    /// @dev FR-C-15 验收：新请求先落地后，旧请求迟到返回不得改写结果
    /// @dev FR-C-15：已结算结果不可被迟到回调改写。
    ///      注意——修复 B 后 DRAWING 期是「先到先得」，不再作废旧请求的回调；
    ///      FR-C-15 的保障由 state 闸提供：一旦 SETTLED，任何迟到回调都被拦下。
    ///      「retryDraw 后旧回调仍可先落定」的先到先得回归见 LotteryRerollGuard.t.sol
    function test_StaleVrfCallback_CannotOverrideResult() public {
        _buy(alice, 10);
        _triggerDraw(1);
        (uint256 firstRequest,) = lottery.vrfRequestOf(1);

        vm.warp(block.timestamp + 3 hours);
        lottery.retryDraw(1);
        (uint256 secondRequest,) = lottery.vrfRequestOf(1);

        // 第二个请求先落地结算
        uint256[] memory words = new uint256[](1);
        words[0] = 222;
        coordinator.fulfillRandomWordsWithOverride(secondRequest, address(lottery), words);
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.SETTLED));

        // 第一个请求的回调迟到：被 state 闸拦下，结果不变
        words[0] = 111;
        coordinator.fulfillRandomWordsWithOverride(firstRequest, address(lottery), words);
        (,,,,,, uint256 seed,,) = lottery.getRound(1);
        assertEq(seed, 222, "settled result is immutable");
    }
}

contract LotterySettleClaimTest is LotteryTestBase {
    function _setupSettledRound100() internal {
        _buy(alice, 10);
        _buy(bob, 20);
        _buy(carol, 70);
        _settleRound(1, 42);
    }

    function test_Settle_SplitsPerTierExactly() public {
        _setupSettledRound100();
        // pot = 99e14 wei：60% / 25%(2名) / 15%(5名)
        assertEq(lottery.perWinnerAmount(1, 0), 594e13);
        assertEq(lottery.perWinnerAmount(1, 1), 12_375e11);
        assertEq(lottery.perWinnerAmount(1, 2), 297000000000000);
        assertEq(_carryOf(2), 0, unicode"无余数时不应有滚存");
    }

    function test_Winners_AreAlwaysRealTicketHolders() public {
        _setupSettledRound100();
        (uint32[] memory tickets, address[] memory winners,) = lottery.winnersOf(1);
        assertEq(tickets.length, 8);
        for (uint256 i = 0; i < tickets.length; i++) {
            assertLt(tickets[i], 100);
            assertEq(winners[i], _linearOwnerOf(1, tickets[i]));
        }
    }

    function test_Claim_FullLifecycle() public {
        _setupSettledRound100();
        (, address[] memory winners,) = lottery.winnersOf(1);
        address tier0Winner = winners[0];

        uint256 before = tier0Winner.balance;
        vm.prank(tier0Winner);
        lottery.claim(1, 0);
        assertEq(tier0Winner.balance - before, 594e13);

        // 重复领取
        vm.prank(tier0Winner);
        vm.expectRevert(Lottery.NothingToClaim.selector);
        lottery.claim(1, 0);
    }

    function test_Claim_MultipleSlotsSameTierPaidTogether() public {
        _setupSettledRound100();
        (, address[] memory winners,) = lottery.winnersOf(1);
        // tier2 的 5 个 slot（索引 3..7），按人归并领取
        for (uint256 i = 3; i < 8; i++) {
            address w = winners[i];
            uint256[] memory pending = lottery.pendingPrizes(1, w);
            if (pending[2] == 0) continue; // 已被同人前次领取
            uint256 before = w.balance;
            vm.prank(w);
            lottery.claim(1, 2);
            assertEq(w.balance - before, pending[2]);
        }
        // 全部领完后 tier2 无剩余
        for (uint256 i = 3; i < 8; i++) {
            assertEq(lottery.pendingPrizes(1, winners[i])[2], 0);
        }
    }

    function test_RevertWhen_NonWinnerClaims() public {
        _setupSettledRound100();
        address outsider = makeAddr("outsider");
        vm.prank(outsider);
        vm.expectRevert(Lottery.NothingToClaim.selector);
        lottery.claim(1, 0);
    }

    /// @dev FR-C-23 验收：暂停售票不影响领奖
    function test_Claim_WorksWhileSalesPaused() public {
        _setupSettledRound100();
        lottery.setSalesPaused(true);
        (, address[] memory winners,) = lottery.winnersOf(1);
        vm.prank(winners[0]);
        lottery.claim(1, 0); // 不 revert 即通过
    }

    function test_RevertWhen_ClaimAfterWindow() public {
        _setupSettledRound100();
        (, address[] memory winners,) = lottery.winnersOf(1);
        vm.warp(_settledAtOf(1) + 90 days + 1);
        vm.prank(winners[0]);
        vm.expectRevert(Lottery.ClaimWindowClosed.selector);
        lottery.claim(1, 0);
    }

    /// @dev FR-C-19：过期未领奖金滚存，任何人可触发。
    ///      修复 A 后钱先入 s_pendingPot 缓冲区（不注入可能已封盘的当前期），
    ///      由下一新期消费。滚存进封盘期的攻击回归见 LotteryCarryTiming.t.sol
    function test_RolloverExpired_BuffersUnclaimed() public {
        _setupSettledRound100();
        vm.warp(_settledAtOf(1) + 90 days + 1);

        vm.prank(makeAddr("anyone"));
        lottery.rolloverExpired(1);
        // 无人领奖：99e6 全额入缓冲
        assertEq(lottery.s_pendingPot(), 99e14);

        vm.expectRevert(Lottery.AlreadyRolledOver.selector);
        lottery.rolloverExpired(1);
    }

    function test_RevertWhen_RolloverBeforeWindowEnds() public {
        _setupSettledRound100();
        vm.expectRevert(Lottery.ClaimWindowNotClosed.selector);
        lottery.rolloverExpired(1);
    }

    /// @dev Q1 验收：3 张票时三等奖（5 名）不开出，其 15% 滚入下期一等奖份额
    function test_Q1_SmallRound_UnopenedTierBuffered() public {
        _buy(alice, 3);
        _settleRound(1, 7);

        // pot = 2.97e14 wei
        assertEq(lottery.perWinnerAmount(1, 0), 178200000000000, unicode"tier0 照常开出");
        assertEq(
            lottery.perWinnerAmount(1, 1),
            37125000000000,
            unicode"tier1 照常开出（2 名 <= 3）"
        );
        assertEq(lottery.perWinnerAmount(1, 2), 0, unicode"tier2 不开出（5 名 > 3）");
        // 修复 A：carry 先入缓冲区，不直接注入当前期
        assertEq(lottery.s_pendingTier1(), 44550000000000, unicode"15% carry 入缓冲");

        vm.prank(alice);
        vm.expectRevert(Lottery.TierNotOpened.selector);
        lottery.claim(1, 2);
    }

    /// @dev Q1 后续：缓冲的 carry 并入之后开出的新期一等奖份额。
    ///      因 FR-C-10「开奖即开下一期」，下一期在本期结算前已开出，故 carry 落在再下一新期
    function test_Q1_CarryPaidIntoLaterTier1() public {
        _buy(alice, 3);
        _settleRound(1, 7); // carry 44550000000000 入缓冲
        assertEq(lottery.s_pendingTier1(), 44550000000000);

        // round2（结算 round1 前已开出）未拿到 carry
        _buy(bob, 100);
        _settleRound(2, 8); // 开出 round3 时消费缓冲
        assertEq(lottery.s_pendingTier1(), 0, "buffer consumed");
        assertEq(lottery.perWinnerAmount(2, 0), 594e13, "round2 jackpot = its own pot only");

        // carry 落入 round3 的一等奖份额
        _buy(carol, 100);
        _settleRound(3, 9);
        assertEq(
            lottery.perWinnerAmount(3, 0), 594e13 + 44550000000000, "round3 jackpot includes carry"
        );
    }

    function test_WithdrawFees_DoesNotTouchPots() public {
        _setupSettledRound100();
        _buy(alice, 50); // round2 再积累一点 fee
        uint256 fees = lottery.s_accruedFees();
        // FR-C-30 之后，_setupSettledRound100 里的那次开奖已把第 1 期抽成的 20%
        // 划给了触发者，因此这里不再是「150 张票 × 1%」的整数，而要扣掉那一笔。
        // 钱没少——它进了 s_pendingKeeperRewards，下面的偿付性断言会一并核对
        uint256 keeperCut = lottery.s_pendingKeeperRewards();
        assertGt(keeperCut, 0, "sanity: the draw paid a keeper reward");
        assertEq(fees + keeperCut, 15e13, "150 tickets x 1%, split across the two buckets");

        uint256 pot1 = 99e14; // round1 已结算未领
        uint256 pot2 = _potOf(2);
        // 第 50 轮 A-1 之后，withdrawFees 会为**当期**（第 2 期，仍 OPEN）的开奖奖励
        // 留一份，因此到账额是 withdrawableFees() 而非裸的 s_accruedFees。
        // 留下的那份仍在 accruedFees 里，会在第 2 期开出时发给触发者
        uint256 withdrawable = lottery.withdrawableFees();
        uint256 reserved = fees - withdrawable;
        assertGt(reserved, 0, "sanity: round 2 is open and reserves its keeper reward");
        vm.prank(makeAddr("anyone"));
        lottery.withdrawFees();

        assertEq(treasury.balance, withdrawable);
        assertEq(lottery.s_accruedFees(), reserved);
        assertEq(_potOf(2), pot2, unicode"奖池不受影响");
        // FR-C-20 验收：提走全部 fees 后，合约余额仍 ≥ 所有未领奖金 + 未领的开奖奖励
        assertGe(address(lottery).balance, pot1 + pot2 + lottery.s_pendingKeeperRewards());
    }

    function test_OwnerCannot_SetFeeAboveCap() public {
        lottery.setFeeBps(1000); // 上限本身允许
        vm.expectRevert(Lottery.FeeTooHigh.selector);
        lottery.setFeeBps(1001); // FR-T-04：owner 也无法突破
    }

    function test_RevertWhen_NonOwnerCallsAdmin() public {
        vm.startPrank(alice);
        vm.expectRevert("Only callable by owner");
        lottery.setFeeBps(50);
        vm.expectRevert("Only callable by owner");
        lottery.setSalesPaused(true);
        vm.expectRevert("Only callable by owner");
        lottery.setTreasury(alice);
        vm.stopPrank();
    }
}

/// @dev FR-T-02（原生 ETH 版）：票价规模变化时账目仍然一致。
///      原条款要求「6 位与 18 位两种 decimals 的 token」，改用原生 ETH 后
///      精度恒为 18 位，改为验证「票价放大 10000 倍」下的分账等比例
contract LotteryPriceScaleTest is LotteryTestBase {
    uint256 internal constant BIG_PRICE = 1 ether; // 默认票价的 10000 倍

    function setUp() public override {
        vm.warp(ANCHOR + 1);
        coordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        subId = coordinator.createSubscription();
        coordinator.fundSubscription(subId, 1000 ether);
        lottery = new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            BIG_PRICE,
            ANCHOR,
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
        coordinator.addConsumer(subId, address(lottery));
        vm.deal(address(this), 10_000 ether);
    }

    function test_LargeTicketPriceAccountingAndClaim() public {
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        lottery.buyTickets{value: BIG_PRICE * 100}(100);

        assertEq(_potOf(1), 99 ether, "pot = 99% of 100 ETH");
        assertEq(lottery.s_accruedFees(), 1 ether, "fee = 1%");
        assertEq(address(lottery).balance, 100 ether);

        _settleRound(1, 42);
        assertEq(lottery.perWinnerAmount(1, 0), 59.4 ether, "tier0 = 60% of pot");

        uint256 before = alice.balance;
        vm.prank(alice); // 唯一持票人必中全部奖级
        lottery.claim(1, 0);
        assertEq(alice.balance - before, 59.4 ether, "native transfer paid exactly");
    }
}
