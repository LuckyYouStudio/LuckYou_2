// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    VRFCoordinatorV2_5Mock
} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Lottery} from "../src/Lottery.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev FR-T-02 性质测试
contract LotteryFuzzTest is LotteryTestBase {
    /// @dev 中奖者永远是本期真实持票人，且中奖票号 < 总票数
    function testFuzz_WinnersAreAlwaysRealTicketHolders(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        uint256 buys = 1 + (seed % 10);
        uint32 total = 0;
        for (uint256 i = 0; i < buys; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint32 qty = uint32(1 + (r % 80));
            _buy(users[r % 3], qty);
            total += qty;
        }
        _settleRound(1, uint256(keccak256(abi.encode(seed, "vrf"))));

        (uint32[] memory tickets, address[] memory winners,) = lottery.winnersOf(1);
        for (uint256 i = 0; i < tickets.length; i++) {
            assertLt(tickets[i], total, "winning ticket out of range");
            address holder = _linearOwnerOf(1, tickets[i]);
            assertTrue(holder != address(0), "winner ticket must exist");
            assertEq(winners[i], holder, "winner must be the real holder");
        }
    }

    /// @dev 领奖总额恒等于结算派发额（无论谁领、领几次）
    function testFuzz_TotalClaimsNeverExceedDistributed(uint256 seed) public {
        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < 3; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            _buy(users[i], uint32(1 + (r % 60)));
        }
        _settleRound(1, seed);

        uint256 distributed = 0;
        uint8[3] memory winnerCounts = [1, 2, 5];
        (,,, uint32 ticketCount,,,,,) = lottery.getRound(1);
        for (uint8 tier = 0; tier < 3; tier++) {
            if (winnerCounts[tier] <= ticketCount) {
                distributed += lottery.perWinnerAmount(1, tier) * winnerCounts[tier];
            }
        }

        uint256 balancesBefore =
            token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol);
        for (uint256 u = 0; u < 3; u++) {
            for (uint8 tier = 0; tier < 3; tier++) {
                vm.prank(users[u]);
                try lottery.claim(1, tier) {} catch {}
            }
        }
        uint256 paid =
            token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol) - balancesBefore;
        assertEq(paid, distributed, "total paid must equal distributed exactly");
    }
}

/// @dev FR-T-02：6 位与 18 位精度下，同一场景账目完全成比例
contract LotteryDualDecimalsTest is LotteryTestBase {
    function _deployStack(uint8 decimals, uint256 price)
        internal
        returns (Lottery l, MockERC20 t, VRFCoordinatorV2_5Mock c)
    {
        c = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        uint256 sid = c.createSubscription();
        c.fundSubscription(sid, 1000 ether);
        t = new MockERC20("T", "T", decimals);
        l = new Lottery(
            address(c),
            sid,
            bytes32(uint256(1)),
            address(t),
            price,
            ANCHOR,
            _intervals(),
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
        c.addConsumer(sid, address(l));
    }

    function _runScenario(Lottery l, MockERC20 t, VRFCoordinatorV2_5Mock c, uint256 price)
        internal
    {
        address[3] memory users = [alice, bob, carol];
        uint32[3] memory qtys = [uint32(13), 27, 60];
        for (uint256 i = 0; i < 3; i++) {
            uint256 cost = price * qtys[i];
            t.mint(users[i], cost);
            vm.startPrank(users[i]);
            t.approve(address(l), cost);
            l.buyTickets(qtys[i]);
            vm.stopPrank();
        }
        vm.warp(ANCHOR + 2 days + 75 minutes);
        l.performUpkeep("");
        (uint256 requestId,) = l.vrfRequestOf(1);
        uint256[] memory words = new uint256[](1);
        words[0] = 12345;
        c.fulfillRandomWordsWithOverride(requestId, address(l), words);
    }

    function test_DualDecimals_ScenarioParity() public {
        (Lottery l6, MockERC20 t6, VRFCoordinatorV2_5Mock c6) = _deployStack(6, 1e6);
        _runScenario(l6, t6, c6, 1e6);
        vm.warp(ANCHOR + 1); // 时间复位，跑 18 位场景
        (Lottery l18, MockERC20 t18, VRFCoordinatorV2_5Mock c18) = _deployStack(18, 1e18);
        _runScenario(l18, t18, c18, 1e18);

        uint256 scale = 1e12;
        (,,,, uint256 pot6,,,,) = l6.getRound(1);
        (,,,, uint256 pot18,,,,) = l18.getRound(1);
        assertEq(pot18, pot6 * scale, "pot parity");
        assertEq(l18.s_accruedFees(), l6.s_accruedFees() * scale, "fee parity");
        for (uint8 tier = 0; tier < 3; tier++) {
            assertEq(
                l18.perWinnerAmount(1, tier),
                l6.perWinnerAmount(1, tier) * scale,
                "perWinner parity"
            );
        }
        // 相同种子与票数分布下，中奖票号完全一致
        (uint32[] memory tk6,,) = l6.winnersOf(1);
        (uint32[] memory tk18,,) = l18.winnersOf(1);
        assertEq(tk6.length, tk18.length);
        for (uint256 i = 0; i < tk6.length; i++) {
            assertEq(tk6[i], tk18[i], "winning tickets identical across decimals");
        }
    }
}
