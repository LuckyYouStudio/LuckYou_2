// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 不能接收原生币的合约钱包（刻意不写 receive/fallback）。
///      ERC20 时代它中奖后照样能收到钱，改用原生币后 claim 恒 revert（R20 M-1）
contract NonPayableWallet {
    Lottery immutable lottery;

    constructor(Lottery l) {
        lottery = l;
    }

    // 只能靠外部先打钱进来才能买票——但它自己收不了款
    function buy(uint32 qty, uint256 value) external {
        uint32 _rid1 = lottery.s_currentRound();
        lottery.buyTickets{value: value}(qty, _rid1);
    }

    function doClaim(uint32 roundId, uint8 tier) external {
        lottery.claim(roundId, tier);
    }

    function doClaimTo(uint32 roundId, uint8 tier, address to) external {
        lottery.claimTo(roundId, tier, to);
    }

    // 刻意不写 receive/fallback
}

/// @dev R20 审计（由另一个审计会话产出）中已核实成立、并已修复的发现的回归测试。
///      注意 AuditR20Poc.t.sol 里的 PoC 断言的是**缺陷行为**，本文件断言的是**修复后的行为**，
///      两者并存：前者说明问题是什么，后者说明出路是什么
contract LotteryR20FixesTest is LotteryTestBase {
    /// @dev M-1：合约钱包收不了原生币时，claim 依然会失败（这是事实，改不了），
    ///      但 claimTo 给了它一条不弃奖的出路
    function test_M1_ClaimToRescuesNonPayableWinner() public {
        NonPayableWallet w = new NonPayableWallet(lottery);
        uint256 cost = PRICE * 10;
        vm.deal(address(w), cost);
        w.buy(10, cost); // 买光全场，必中所有奖级
        _settleRound(1, 42);

        uint256 prize = lottery.perWinnerAmount(1, 0);
        assertGt(prize, 0);

        // 直接领：收款失败，钱拿不出来
        vm.expectRevert(Lottery.TransferFailed.selector);
        w.doClaim(1, 0);

        // 指定一个能收款的地址：奖金到账，不再被 90 天后扫走
        uint256 before = alice.balance;
        w.doClaimTo(1, 0, alice);
        assertEq(alice.balance - before, prize, "prize rescued to a payable address");

        // 已领过就不能再领（claimedBits 照常生效，两条路径共用同一份记账）
        vm.expectRevert(Lottery.NothingToClaim.selector);
        w.doClaimTo(1, 0, alice);
    }

    /// @dev M-1：claimTo 不得成为「替别人领奖」的口子——中奖判定恒以 msg.sender 持票为准
    function test_RevertWhen_ClaimToStealsAnotherWinnersPrize() public {
        _buy(alice, 10); // alice 独占全场
        _settleRound(1, 42);

        // bob 没有票，指定收款地址也拿不到任何东西
        vm.prank(bob);
        vm.expectRevert(Lottery.NothingToClaim.selector);
        lottery.claimTo(1, 0, bob);

        // alice 自己领得到
        uint256 before = carol.balance;
        vm.prank(alice);
        lottery.claimTo(1, 0, carol);
        assertEq(carol.balance - before, lottery.perWinnerAmount(1, 0));
    }

    /// @dev M-1：收款地址不得为零地址（否则奖金直接烧掉）
    function test_RevertWhen_ClaimToZeroAddress() public {
        _buy(alice, 10);
        _settleRound(1, 42);
        vm.prank(alice);
        vm.expectRevert(Lottery.InvalidRecipient.selector);
        lottery.claimTo(1, 0, address(0));
    }

    /// @dev I-2：比例为 0 的奖级永远开不出，却照样占用 16 个 slot 的名额预算——构造时拒绝
    function test_RevertWhen_TierBpsIsZero() public {
        uint16[] memory bad = new uint16[](3);
        bad[0] = 10000; // 其余两档为 0，和仍然是 10000，旧实现会接受
        bad[1] = 0;
        bad[2] = 0;
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
            bad,
            _tierWinners()
        );
    }

    /// @dev L-4：远古锚点会让构造时的日程追赶循环跑到 OOG。
    ///      日程全合约无 setter，配错只能重新部署，所以要失败得清楚
    function test_RevertWhen_AnchorTimeIsAncient() public {
        vm.expectRevert(Lottery.InvalidSchedule.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            PRICE,
            1, // 1970 年的锚点
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
    }

    /// @dev L-4 边界：一年以内的锚点仍然合法（正常部署不受影响）
    function test_RecentAnchorStillAccepted() public {
        Lottery ok = new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            PRICE,
            uint64(block.timestamp - 300 days),
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
        assertEq(ok.s_currentRound(), 1, "a 300-day-old anchor deploys fine");
    }

    // =====================================================================
    // R20 L-1：buyTickets 必须由调用者带上期号（2026-08-15 修复）
    // =====================================================================

    /// @dev 这是这条修复要防的**真实场景**，不是抽象的参数校验：用户在第 1 期下单，
    ///      交易还躺在内存池里时 `performUpkeep` 把期翻到了第 2 期。修复前这笔钱会
    ///      静默买进第 2 期——奖池规模、已售票数、中奖概率、距停售还剩多久全都变了，
    ///      买到的不是看到的。修复后直接 revert，钱退回用户手里由他重新决定。
    function test_RevertWhen_RoundRolledOverWhileTxWasPending() public {
        _buy(bob, 1); // 第 1 期已有别人买票，因此会走正常开奖而非零票 VOID
        uint32 seen = lottery.s_currentRound(); // 用户下单那一刻看到的期号
        assertEq(seen, 1);

        // 交易排队期间，任何人都可以触发开奖把期推进（performUpkeep 无权限）
        _settleRound(1, 7);
        assertEq(lottery.s_currentRound(), 2, "the round advanced under the user's feet");

        uint256 cost = PRICE * 3;
        vm.deal(alice, alice.balance + cost);
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Lottery.RoundMismatch.selector, seen, uint32(2)));
        lottery.buyTickets{value: cost}(3, seen);

        // 钱一分没动，第 2 期也没有凭空多出票来
        assertEq(alice.balance, balanceBefore, "the user's ETH never left");
        (,,, uint32 tc2,,,,,) = lottery.getRound(2);
        assertEq(tc2, 0, "nothing was bought into the round the user never chose");
    }

    /// @dev 反向守卫：期号相符时必须照常成交，别把闸开过头
    function test_BuyWithMatchingRoundIdStillSucceeds() public {
        uint32 seen = lottery.s_currentRound();
        uint256 cost = PRICE * 3;
        vm.deal(alice, alice.balance + cost);
        vm.prank(alice);
        lottery.buyTickets{value: cost}(3, seen);
        (,,, uint32 tc,,,,,) = lottery.getRound(seen);
        assertEq(tc, 3, "a matching round id buys normally");
    }

    /// @dev 未来期号同样必须拒绝。只挡「翻过头」是不够的——传入一个尚未开出的期号
    ///      说明调用者的世界观本来就是错的，此时成交同样是错误成交
    function test_RevertWhen_ExpectedRoundIdIsInTheFuture() public {
        uint256 cost = PRICE;
        vm.deal(alice, alice.balance + cost);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Lottery.RoundMismatch.selector, uint32(99), uint32(1))
        );
        lottery.buyTickets{value: cost}(1, 99);
    }
}
