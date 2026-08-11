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
        lottery.buyTickets{value: value}(qty);
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
}
