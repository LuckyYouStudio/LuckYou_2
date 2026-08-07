// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    VRFCoordinatorV2_5Mock
} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Lottery} from "../src/Lottery.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @dev 共享测试基座：VRF mock + 6 位精度 token + 默认参数的 Lottery
contract LotteryTestBase is Test {
    uint64 internal constant ANCHOR = 1_700_000_000;
    uint256 internal constant PRICE = 1e6; // 1 USDC
    uint16 internal constant FEE_BPS = 100; // 1%

    VRFCoordinatorV2_5Mock internal coordinator;
    MockERC20 internal token;
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
        token = new MockERC20("Mock USDC", "USDC", 6);
        lottery = _deployLottery(address(token));
        coordinator.addConsumer(subId, address(lottery));
    }

    function _deployLottery(address token_) internal returns (Lottery) {
        return new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            token_,
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
        token.mint(user, cost);
        vm.startPrank(user);
        token.approve(address(lottery), cost);
        lottery.buyTickets(qty);
        vm.stopPrank();
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
        Lottery.TicketRange[] memory ranges = lottery.getRanges(roundId);
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
            address(token),
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
            address(token),
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
            address(token),
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
        // 100 USDC，1% 抽成
        assertEq(_potOf(1), 99e6, "pot");
        assertEq(lottery.s_accruedFees(), 1e6, "fees");
        assertEq(token.balanceOf(address(lottery)), 100e6, "balance");
        Lottery.TicketRange[] memory ranges = lottery.getRanges(1);
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
        Lottery.TicketRange[] memory ranges = lottery.getRanges(1);
        assertEq(ranges.length, 3);
        assertEq(ranges[1].start, 10);
        assertEq(ranges[1].end, 15);
        assertEq(ranges[2].start, 15);
        assertEq(ranges[2].end, 18);
        assertEq(lottery.ticketsOwned(1, alice), 13);
    }

    function test_RevertWhen_BuyAtOrAfterCloseTime() public {
        vm.warp(_closeTimeOf(1)); // FR-C-09：即使 keeper 未触发也拒绝
        token.mint(alice, PRICE);
        vm.startPrank(alice);
        token.approve(address(lottery), PRICE);
        vm.expectRevert(Lottery.SalesClosed.selector);
        lottery.buyTickets(1);
        vm.stopPrank();
    }

    function test_RevertWhen_BuyWhilePaused() public {
        lottery.setSalesPaused(true);
        token.mint(alice, PRICE);
        vm.startPrank(alice);
        token.approve(address(lottery), PRICE);
        vm.expectRevert(Lottery.SalesArePaused.selector);
        lottery.buyTickets(1);
        vm.stopPrank();
    }

    function test_RevertWhen_BuyZeroOrOverMax() public {
        token.mint(alice, PRICE * 2000);
        vm.startPrank(alice);
        token.approve(address(lottery), PRICE * 2000);
        vm.expectRevert(Lottery.InvalidQuantity.selector);
        lottery.buyTickets(0);
        vm.expectRevert(Lottery.ExceedsMaxPerTx.selector);
        lottery.buyTickets(1001); // FR-C-06
        vm.stopPrank();
    }

    /// @dev FR-C-04 验收：批量购买 gas 亚线性
    function test_Gas_Buy100LessThan3xBuy10() public {
        _buy(carol, 1); // 预热存储槽

        token.mint(alice, PRICE * 110);
        vm.startPrank(alice);
        token.approve(address(lottery), PRICE * 110);
        uint256 g0 = gasleft();
        lottery.buyTickets(10);
        uint256 gas10 = g0 - gasleft();
        g0 = gasleft();
        lottery.buyTickets(100);
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
        token.mint(alice, 50e6);
        vm.startPrank(alice);
        token.approve(address(lottery), 50e6);
        lottery.injectPot(1, 50e6);
        vm.stopPrank();
        assertEq(_potOf(1), 50e6);
        assertEq(lottery.s_accruedFees(), 0); // FR-C-26 验收：注资不抽成
    }

    function test_RevertWhen_InjectNotOpenRound() public {
        _buy(alice, 1);
        _triggerDraw(1); // round1 进入 DRAWING
        token.mint(alice, 1e6);
        vm.startPrank(alice);
        token.approve(address(lottery), 1e6);
        vm.expectRevert(Lottery.RoundNotOpen.selector);
        lottery.injectPot(1, 1e6);
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

    /// @dev FR-C-26：VOIDED 期的注资滚入下期奖池
    function test_VoidedRound_InjectionRollsToNextPot() public {
        token.mint(alice, 50e6);
        vm.startPrank(alice);
        token.approve(address(lottery), 50e6);
        lottery.injectPot(1, 50e6);
        vm.stopPrank();

        vm.warp(_drawTimeOf(1));
        vm.expectEmit(true, true, false, true);
        emit Lottery.PrizeRolledOver(1, 2, 50e6);
        lottery.performUpkeep("");
        assertEq(_potOf(2), 50e6);
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
    function test_StaleVrfCallback_CannotOverrideResult() public {
        _buy(alice, 10);
        _triggerDraw(1);
        (uint256 oldRequest,) = lottery.vrfRequestOf(1);

        vm.warp(block.timestamp + 3 hours);
        lottery.retryDraw(1);

        // 旧请求先到：静默忽略
        uint256[] memory words = new uint256[](1);
        words[0] = 111;
        coordinator.fulfillRandomWordsWithOverride(oldRequest, address(lottery), words);
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.DRAWING));
        (,,,,,, uint256 seed,,) = lottery.getRound(1);
        assertEq(seed, 0);

        // 新请求落地：正常结算
        _fulfill(1, 222);
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.SETTLED));
        (,,,,,, seed,,) = lottery.getRound(1);
        assertEq(seed, 222);
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
        // pot = 99e6：60% / 25%(2名) / 15%(5名)
        assertEq(lottery.perWinnerAmount(1, 0), 594e5);
        assertEq(lottery.perWinnerAmount(1, 1), 12_375e3);
        assertEq(lottery.perWinnerAmount(1, 2), 2_970e3);
        assertEq(_carryOf(2), 0, unicode"无余数时不应有滚存");
    }

    function test_Winners_AreAlwaysRealTicketHolders() public {
        _setupSettledRound100();
        (uint32[] memory tickets, address[] memory winners) = lottery.winnersOf(1);
        assertEq(tickets.length, 8);
        for (uint256 i = 0; i < tickets.length; i++) {
            assertLt(tickets[i], 100);
            assertEq(winners[i], _linearOwnerOf(1, tickets[i]));
        }
    }

    function test_Claim_FullLifecycle() public {
        _setupSettledRound100();
        (, address[] memory winners) = lottery.winnersOf(1);
        address tier0Winner = winners[0];

        uint256 before = token.balanceOf(tier0Winner);
        vm.prank(tier0Winner);
        lottery.claim(1, 0);
        assertEq(token.balanceOf(tier0Winner) - before, 594e5);

        // 重复领取
        vm.prank(tier0Winner);
        vm.expectRevert(Lottery.NothingToClaim.selector);
        lottery.claim(1, 0);
    }

    function test_Claim_MultipleSlotsSameTierPaidTogether() public {
        _setupSettledRound100();
        (, address[] memory winners) = lottery.winnersOf(1);
        // tier2 的 5 个 slot（索引 3..7），按人归并领取
        for (uint256 i = 3; i < 8; i++) {
            address w = winners[i];
            uint256[] memory pending = lottery.pendingPrizes(1, w);
            if (pending[2] == 0) continue; // 已被同人前次领取
            uint256 before = token.balanceOf(w);
            vm.prank(w);
            lottery.claim(1, 2);
            assertEq(token.balanceOf(w) - before, pending[2]);
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
        (, address[] memory winners) = lottery.winnersOf(1);
        vm.prank(winners[0]);
        lottery.claim(1, 0); // 不 revert 即通过
    }

    function test_RevertWhen_ClaimAfterWindow() public {
        _setupSettledRound100();
        (, address[] memory winners) = lottery.winnersOf(1);
        vm.warp(_closeTimeOf(1) + 90 days + 1);
        vm.prank(winners[0]);
        vm.expectRevert(Lottery.ClaimWindowClosed.selector);
        lottery.claim(1, 0);
    }

    /// @dev FR-C-19：过期未领奖金滚入当前期奖池，任何人可触发
    function test_RolloverExpired_MovesUnclaimedToCurrentPot() public {
        _setupSettledRound100();
        vm.warp(_closeTimeOf(1) + 90 days + 1);

        uint32 current = lottery.s_currentRound();
        uint256 potBefore = _potOf(current);
        vm.prank(makeAddr("anyone"));
        lottery.rolloverExpired(1);
        // 无人领奖：99e6 全额滚存
        assertEq(_potOf(current) - potBefore, 99e6);

        vm.expectRevert(Lottery.AlreadyRolledOver.selector);
        lottery.rolloverExpired(1);
    }

    function test_RevertWhen_RolloverBeforeWindowEnds() public {
        _setupSettledRound100();
        vm.expectRevert(Lottery.ClaimWindowNotClosed.selector);
        lottery.rolloverExpired(1);
    }

    /// @dev Q1 验收：3 张票时三等奖（5 名）不开出，其 15% 滚入下期一等奖份额
    function test_Q1_SmallRound_UnopenedTierRollsToNextTier1Carry() public {
        _buy(alice, 3);
        _settleRound(1, 7);

        // pot = 2.97e6
        assertEq(lottery.perWinnerAmount(1, 0), 1_782e3, unicode"tier0 照常开出");
        assertEq(
            lottery.perWinnerAmount(1, 1), 371_250, unicode"tier1 照常开出（2 名 <= 3）"
        );
        assertEq(lottery.perWinnerAmount(1, 2), 0, unicode"tier2 不开出（5 名 > 3）");
        assertEq(_carryOf(2), 445_500, unicode"15% 滚入下期一等奖份额");

        vm.prank(alice);
        vm.expectRevert(Lottery.TierNotOpened.selector);
        lottery.claim(1, 2);
    }

    /// @dev Q1 后续：下期一等奖份额 = 下期 pot 的 60% + 上期滚存
    function test_Q1_CarryPaidIntoNextTier1() public {
        _buy(alice, 3);
        _settleRound(1, 7);
        assertEq(_carryOf(2), 445_500);

        _buy(bob, 100);
        _settleRound(2, 8);
        // round2 pot = 99e6：tier0 = 59.4e6 + 445500
        assertEq(lottery.perWinnerAmount(2, 0), 594e5 + 445_500);
    }

    function test_WithdrawFees_DoesNotTouchPots() public {
        _setupSettledRound100();
        _buy(alice, 50); // round2 再积累一点 fee
        uint256 fees = lottery.s_accruedFees();
        assertEq(fees, 15e5); // 150 张票 × 1%

        uint256 pot1 = 99e6; // round1 已结算未领
        uint256 pot2 = _potOf(2);
        vm.prank(makeAddr("anyone"));
        lottery.withdrawFees();

        assertEq(token.balanceOf(treasury), fees);
        assertEq(lottery.s_accruedFees(), 0);
        assertEq(_potOf(2), pot2, unicode"奖池不受影响");
        // FR-C-20 验收：提走全部 fees 后，合约余额仍 ≥ 所有未领奖金
        assertGe(token.balanceOf(address(lottery)), pot1 + pot2);
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

/// @dev FR-T-02：18 位精度 token 下账目一致（完整双精度套件在 M2）
contract LotteryDecimals18Test is LotteryTestBase {
    function setUp() public override {
        vm.warp(ANCHOR + 1);
        coordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        subId = coordinator.createSubscription();
        coordinator.fundSubscription(subId, 1000 ether);
        token = new MockERC20("Mock DAI", "DAI", 18);
        lottery = new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            address(token),
            1e18,
            ANCHOR,
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
        coordinator.addConsumer(subId, address(lottery));
    }

    function test_Decimals18_AccountingAndClaim() public {
        token.mint(alice, 100e18);
        vm.startPrank(alice);
        token.approve(address(lottery), 100e18);
        lottery.buyTickets(100);
        vm.stopPrank();

        assertEq(_potOf(1), 99e18);
        assertEq(lottery.s_accruedFees(), 1e18);

        _settleRound(1, 42);
        assertEq(lottery.perWinnerAmount(1, 0), 594e17);

        vm.prank(alice); // 唯一持票人必中全部奖级
        lottery.claim(1, 0);
        assertEq(token.balanceOf(alice), 594e17);
    }
}
