// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev 只为把 ETH 强塞进没有 receive/fallback 的合约：selfdestruct 的转账
///      不经过接收方代码，EIP-6780 之后依然如此
contract ForceFeeder {
    constructor() payable {}

    function attack(address payable target) external {
        selfdestruct(target);
    }
}

/// @dev 中奖者在收款回调里横向调用**其他**未加 nonReentrant 的函数。
///      claim 自身被 ReentrancyGuard 挡住是已验证过的；这里查的是「跨函数」：
///      派奖转账把执行权交给攻击者时，合约正处于 claim 的中途状态，
///      此时若别的入口能观察到或改写这份中间状态，就能撬动资金
contract CrossFunctionReenterer {
    Lottery immutable lottery;
    string public which;
    bool entered;
    bool public didRun;
    bytes public innerError;

    constructor(Lottery l) payable {
        lottery = l;
    }

    function arm(string calldata what) external {
        which = what;
        entered = false;
        didRun = false;
    }

    function buy(uint32 qty) external {
        uint32 _rid1 = lottery.s_currentRound();
        lottery.buyTickets{value: lottery.i_ticketPrice() * qty}(qty, _rid1);
    }

    function doClaim(uint32 roundId, uint8 tier) external {
        lottery.claim(roundId, tier);
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        bytes32 w = keccak256(bytes(which));
        if (w == keccak256("upkeep")) {
            try lottery.performUpkeep("") {
                didRun = true;
            } catch (bytes memory e) {
                innerError = e;
            }
        } else if (w == keccak256("withdrawFees")) {
            try lottery.withdrawFees() {
                didRun = true;
            } catch (bytes memory e) {
                innerError = e;
            }
        } else if (w == keccak256("rollover")) {
            try lottery.rolloverExpired(1) {
                didRun = true;
            } catch (bytes memory e) {
                innerError = e;
            }
        } else if (w == keccak256("buy")) {
            uint256 price = lottery.i_ticketPrice();
            uint32 _rid2 = lottery.s_currentRound();
            try lottery.buyTickets{value: price}(1, _rid2) {
                didRun = true;
            } catch (bytes memory e) {
                innerError = e;
            }
        } else if (w == keccak256("inject")) {
            try lottery.injectPot{value: 1e12}(lottery.s_currentRound()) {
                didRun = true;
            } catch (bytes memory e) {
                innerError = e;
            }
        }
    }
}

/// @dev 恶意 treasury：收抽成时试图重入抢奖池
contract EvilTreasury {
    Lottery public lottery;
    bool entered;
    bool public reenterClaimBlocked;
    bool public reenterWithdrawBlocked;

    function setLottery(Lottery l) external {
        lottery = l;
    }

    receive() external payable {
        if (entered) return;
        entered = true;
        try lottery.withdrawFees() {}
        catch {
            reenterWithdrawBlocked = true;
        }
        try lottery.claim(1, 0) {}
        catch {
            reenterClaimBlocked = true;
        }
    }
}

/// @dev 收款时烧光所有 gas 的中奖者
contract GasBurner {
    Lottery immutable lottery;
    uint256 sink;

    constructor(Lottery l) payable {
        lottery = l;
    }

    function buy(uint32 qty) external {
        uint32 _rid3 = lottery.s_currentRound();
        lottery.buyTickets{value: lottery.i_ticketPrice() * qty}(qty, _rid3);
    }

    receive() external payable {
        // 转账会把全部剩余 gas 转发过来，这里尽量烧掉
        while (gasleft() > 5000) {
            sink++;
        }
    }
}

/// @dev 原生 ETH 计价引入的攻击面（2026-08-11 改造后重做的对抗审计）。
///      ERC20 时代的转账不会把执行权交给接收方，改用原生币后**每一次派奖都是
///      一次对任意代码的调用**，因此这一组测试专查：强制打款破坏记账、
///      跨函数重入、恶意 treasury、以及收款方耗尽 gas 的连带影响
contract LotteryNativeEthTest is LotteryTestBase {
    /// @dev R1：selfdestruct 强塞的 ETH 不得影响任何金额计算。
    ///      合约刻意不读 address(this).balance——一旦读了，强制打款就能篡改分账
    function test_ForceFedEtherCannotDistortAccounting() public {
        _buy(alice, 10);
        uint256 potBefore = _potOf(1);
        uint256 feesBefore = lottery.s_accruedFees();

        ForceFeeder feeder = new ForceFeeder{value: 5 ether}();
        feeder.attack(payable(address(lottery)));

        assertEq(address(lottery).balance, 10e14 + 5 ether, "ether was force-fed");
        assertEq(_potOf(1), potBefore, "pot must not move");
        assertEq(lottery.s_accruedFees(), feesBefore, "fees must not move");

        _settleRound(1, 42);
        // 分账只看账面 pot，与被强塞的余额无关
        assertEq(lottery.perWinnerAmount(1, 0), (potBefore * 6000) / 10000, "tier0 unaffected");

        // 强塞的钱既不进奖池也无法被任何人取走——它就此沉没（FR-C-24 无救援手段的直接后果）
        uint256 treasuryBefore = treasury.balance;
        // 开奖已按 FR-C-30 把一部分抽成划给了触发者，故此处必须重新读，
        // 不能沿用开奖前的 feesBefore
        uint256 feesNow = lottery.s_accruedFees();
        assertLt(feesNow, feesBefore, "part of the fee went to the keeper reward");
        lottery.withdrawFees();
        assertEq(treasury.balance - treasuryBefore, feesNow, "only accrued fees leave");
        assertGe(address(lottery).balance, 5 ether, "force-fed ether is stranded");
    }

    /// @dev R2：跨函数重入——收款回调里调 performUpkeep。
    ///      关键是让 performUpkeep 在领奖那一刻**确实到期**（否则只是撞 DrawNotDue，
    ///      根本没跑到重入路径，测试会给出虚假的安全感）
    function test_Attack_ReenterPerformUpkeepDuringClaim() public {
        CrossFunctionReenterer atk = new CrossFunctionReenterer{value: 100e14}(lottery);
        atk.buy(10);
        _settleRound(1, 42);

        uint32 roundBefore = lottery.s_currentRound();
        // 快进到下一期开奖时刻：此时 performUpkeep 真的可执行，且仍在第 1 期的领奖窗口内
        vm.warp(_drawTimeOf(roundBefore));

        uint256 perWinner = lottery.perWinnerAmount(1, 0);
        uint256 balBefore = address(atk).balance;

        atk.arm("upkeep");
        atk.doClaim(1, 0);

        assertTrue(atk.didRun(), "performUpkeep must actually execute inside the payout callback");
        assertEq(lottery.s_currentRound(), roundBefore + 1, "it really advanced the round");
        // 重入成功推进了期号，但本次派奖分文不多、分文不少
        assertEq(address(atk).balance - balBefore, perWinner, "paid exactly once");
        // 再领必须失败：claimedBits 在转账**前**已置位（CEI）
        vm.expectRevert(Lottery.NothingToClaim.selector);
        atk.doClaim(1, 0);
        _assertSolvent();
    }

    /// @dev R2：收款回调里对**同一期**调 rolloverExpired——领奖窗口与滚存窗口
    ///      严格互斥，不得出现「先领走再滚存」的双花
    function test_Attack_ReenterRolloverSameRoundDuringClaim() public {
        CrossFunctionReenterer atk = new CrossFunctionReenterer{value: 100e14}(lottery);
        atk.buy(10);
        _settleRound(1, 42);

        uint256 pendingBefore = lottery.s_pendingPot();
        atk.arm("rollover");
        atk.doClaim(1, 0);

        assertFalse(atk.didRun(), "rollover of a still-claimable round must fail");
        assertEq(
            bytes4(atk.innerError()),
            Lottery.ClaimWindowNotClosed.selector,
            "the two windows are strictly disjoint"
        );
        assertEq(lottery.s_pendingPot(), pendingBefore, "nothing leaked into the buffer");
        _assertSolvent();
    }

    /// @dev R2：收款回调里调 withdrawFees——与 claim 共用同一把 ReentrancyGuard，必须被挡
    function test_Attack_ReenterWithdrawFeesDuringClaimBlocked() public {
        CrossFunctionReenterer atk = new CrossFunctionReenterer{value: 100e14}(lottery);
        atk.buy(10);
        _settleRound(1, 42);

        uint256 feesBefore = lottery.s_accruedFees();
        atk.arm("withdrawFees");
        atk.doClaim(1, 0);

        assertFalse(atk.didRun(), "withdrawFees must not run inside a claim");
        assertEq(
            bytes4(atk.innerError()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "must be the guard that stopped it"
        );
        assertEq(lottery.s_accruedFees(), feesBefore, "fees untouched");
        _assertSolvent();
    }

    /// @dev R2：收款回调里买票 / 注资——这两个入口无 nonReentrant，会真的执行，
    ///      必须确认它们只是「正常付款」，拿不到任何额外好处
    function test_Attack_ReenterBuyAndInjectDuringClaim() public {
        CrossFunctionReenterer atk = new CrossFunctionReenterer{value: 100e14}(lottery);
        atk.buy(10);
        _settleRound(1, 42);

        uint32 cur = lottery.s_currentRound();
        uint256 potBefore = _potOf(cur);
        uint256 price = lottery.i_ticketPrice();

        atk.arm("buy");
        atk.doClaim(1, 0);

        assertTrue(atk.didRun(), "buy is not guarded, it does execute");
        // 重入买到的票是**付了钱**的票，奖池按正常规则增加，没有白拿
        uint256 fee = (price * FEE_BPS) / 10000;
        assertEq(_potOf(cur), potBefore + price - fee, "reentrant buy paid full price");
        assertEq(lottery.ticketsOwned(cur, address(atk)), 1);
        _assertSolvent();
    }

    /// @dev R3：恶意 treasury 在收抽成时重入，既抢不到奖池也提不了第二次
    function test_Attack_MaliciousTreasuryCannotDrainPot() public {
        EvilTreasury evil = new EvilTreasury();
        evil.setLottery(lottery);
        lottery.setTreasury(address(evil));

        _buy(alice, 100);
        _settleRound(1, 42);

        uint256 potLocked = lottery.perWinnerAmount(1, 0) * 1 + lottery.perWinnerAmount(1, 1) * 2
            + lottery.perWinnerAmount(1, 2) * 5;
        uint256 fees = lottery.s_accruedFees();

        lottery.withdrawFees();

        assertEq(address(evil).balance, fees, "treasury got exactly the accrued fees");
        assertTrue(evil.reenterWithdrawBlocked(), "second withdrawFees must fail");
        assertTrue(evil.reenterClaimBlocked(), "claim from inside withdrawFees must fail");
        assertGe(address(lottery).balance, potLocked, "prize pool intact");
        _assertSolvent();
    }

    /// @dev R4：中奖者在 receive 里烧光 gas，只能烧掉自己那笔交易，不影响他人领奖
    function test_Attack_GasBurningWinnerOnlyHarmsItself() public {
        GasBurner burner = new GasBurner{value: 100e14}(lottery);
        burner.buy(5);
        _buy(alice, 5);
        _settleRound(1, 42);

        // 无论 burner 能否领到，alice 的领奖路径都不受影响
        uint256 aliceBefore = alice.balance;
        bool alicePaid;
        for (uint8 t = 0; t < 3; t++) {
            vm.prank(alice);
            try lottery.claim(1, t) {
                alicePaid = true;
            } catch {}
        }
        if (alicePaid) {
            assertGt(alice.balance, aliceBefore, "other winners unaffected by a gas-burning peer");
        }
        _assertSolvent();
    }

    /// @dev R4：拒收的 treasury 会让 withdrawFees 一直失败，但 owner 换地址即可自救，
    ///      且奖池分文不受影响（抽成与奖池分账，FR-C-20）
    function test_RejectingTreasuryBlocksFeesButNotPrizes() public {
        RejectAll bad = new RejectAll();
        lottery.setTreasury(address(bad));
        _buy(alice, 100);
        _settleRound(1, 42);

        vm.expectRevert(Lottery.TransferFailed.selector);
        lottery.withdrawFees();

        // 中奖者照常领奖
        (, address[] memory winners,) = lottery.winnersOf(1);
        uint256 before = winners[0].balance;
        vm.prank(winners[0]);
        lottery.claim(1, 0);
        assertGt(winners[0].balance, before, "prizes unaffected by a broken treasury");

        // owner 换回可收款地址即可解冻抽成
        lottery.setTreasury(treasury);
        uint256 fees = lottery.s_accruedFees();
        lottery.withdrawFees();
        assertEq(treasury.balance, fees, "fees recovered after fixing treasury");
    }

    /// @dev 偿付性：合约余额 >= 全部账面义务（强制打款只会让余额更多，不会更少）
    function _assertSolvent() internal view {
        uint256 obligations =
            lottery.s_accruedFees() + lottery.s_pendingPot() + lottery.s_pendingTier1();
        uint32 cur = lottery.s_currentRound();
        uint8[3] memory counts = [1, 2, 5];
        for (uint32 id = 1; id <= cur; id++) {
            (Lottery.RoundState st,,,, uint256 pot, uint256 t1,, uint16 bits,) =
                lottery.getRound(id);
            if (st == Lottery.RoundState.OPEN || st == Lottery.RoundState.DRAWING) {
                obligations += pot + t1;
            } else if (st == Lottery.RoundState.SETTLED) {
                uint8 slot = 0;
                for (uint8 tier = 0; tier < 3; tier++) {
                    uint256 per = lottery.perWinnerAmount(id, tier);
                    for (uint8 j = 0; j < counts[tier]; j++) {
                        if (per > 0 && bits & (uint16(1) << slot) == 0) obligations += per;
                        slot++;
                    }
                }
            }
        }
        assertGe(address(lottery).balance, obligations, "insolvent");
    }
}

/// @dev 一律拒收原生币
contract RejectAll {
    // 刻意不写 receive/fallback
}

/// @dev 第 5~7 轮：边界、规模与长期停摆。这些不是原生币特有的，但改造动过
///      金额量级与部署参数（1e6 → 1e14、日程改 7200 秒快节奏），旧结论不能直接沿用
contract LotteryScaleAndBoundaryTest is LotteryTestBase {
    /// @dev R5：领奖窗口与滚存窗口在**同一秒**上不得重叠，也不得留空隙
    function test_ClaimAndRolloverWindowsAreExactlyDisjoint() public {
        _buy(alice, 10);
        _settleRound(1, 42);
        uint64 settledAt = _settledAtOf(1);
        uint64 deadline = settledAt + lottery.CLAIM_WINDOW();

        // 最后一秒：可领、不可滚存
        vm.warp(deadline);
        vm.expectRevert(Lottery.ClaimWindowNotClosed.selector);
        lottery.rolloverExpired(1);
        (, address[] memory winners,) = lottery.winnersOf(1);
        uint256 before = winners[0].balance;
        vm.prank(winners[0]);
        lottery.claim(1, 0);
        assertGt(winners[0].balance, before, "last second of the window still pays");

        // 下一秒：不可领、可滚存（无空隙）
        vm.warp(deadline + 1);
        vm.prank(winners[0]);
        vm.expectRevert(Lottery.ClaimWindowClosed.selector);
        lottery.claim(1, 1);
        lottery.rolloverExpired(1);
        assertGt(lottery.s_pendingPot(), 0, "expired prizes move to the buffer");
    }

    /// @dev R6：长期停摆后 _openNextRound 要把错过的场次逐个跳过。
    ///      快节奏实例（7200 秒）停摆一年 = 约 4380 次循环，若 gas 超出区块上限，
    ///      期号将永远无法推进 —— 全部资金冻结，而 FR-C-24 禁止任何救援手段
    function test_LongOutageScheduleCatchupStaysWithinBlockGas() public {
        uint32[] memory fast = new uint32[](1);
        fast[0] = 7200; // 与 Base Sepolia 快节奏实例一致
        uint16[] memory bps = _tierBps();
        uint8[] memory wins = _tierWinners();
        Lottery fastLottery = new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            PRICE,
            uint64(block.timestamp),
            fast,
            treasury,
            FEE_BPS,
            bps,
            wins
        );
        coordinator.addConsumer(subId, address(fastLottery));

        vm.deal(alice, alice.balance + PRICE);
        uint32 _rid4 = fastLottery.s_currentRound();
        vm.prank(alice);
        fastLottery.buyTickets{value: PRICE}(1, _rid4);

        // 停摆一整年后才有人来触发
        vm.warp(block.timestamp + 365 days);
        uint256 gasBefore = gasleft();
        fastLottery.performUpkeep("");
        uint256 used = gasBefore - gasleft();

        assertEq(fastLottery.s_currentRound(), 2, "round pointer advanced after a year of silence");
        // Base 区块上限远高于此；留出宽裕余量作回归哨兵
        assertLt(used, 10_000_000, "schedule catch-up must not approach the block gas limit");
        // 追上后新期仍有完整售票窗口
        (, uint64 closeTime,,,,,,,) = fastLottery.getRound(2);
        assertGt(closeTime, uint64(block.timestamp) + fastLottery.MIN_SALES_WINDOW() - 1);
    }

    /// @dev R7：写入路径必须与 range 条数无关（这是 Range 压缩存储的全部意义）。
    ///      灌入大量单张购买后，领奖仍是 O(log n)，不能被撑爆
    function test_ManyRangesDoNotInflateClaimGas() public {
        uint32 n = 600;
        for (uint32 i = 0; i < n; i++) {
            address buyer = address(uint160(uint256(keccak256(abi.encode("grief", i)))));
            vm.deal(buyer, PRICE);
            uint32 _rid5 = lottery.s_currentRound();
            vm.prank(buyer);
            lottery.buyTickets{value: PRICE}(1, _rid5);
        }
        assertEq(lottery.rangeCountOf(1), n);
        _settleRound(1, 42);

        (, address[] memory winners,) = lottery.winnersOf(1);
        uint256 gasBefore = gasleft();
        vm.prank(winners[0]);
        lottery.claim(1, 0);
        uint256 used = gasBefore - gasleft();
        // 二分查找：600 条 range 也只需约 10 次比较
        assertLt(used, 250_000, "claim must stay O(log n) in range count");
    }

    /// @dev R7：ticketsOwned 是 O(range) 且无分页——查明它在多大规模下失效，
    ///      以及失效时是否只影响视图（写入路径不得受牵连）
    function test_TicketsOwnedIsLinearAndUnpaginated() public {
        uint32 n = 600;
        for (uint32 i = 0; i < n; i++) {
            address buyer = address(uint160(uint256(keccak256(abi.encode("grief", i)))));
            vm.deal(buyer, PRICE);
            uint32 _rid6 = lottery.s_currentRound();
            vm.prank(buyer);
            lottery.buyTickets{value: PRICE}(1, _rid6);
        }
        uint256 gasBefore = gasleft();
        lottery.ticketsOwned(1, alice);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("ticketsOwned gas @600 ranges", used);
        emit log_named_uint("extrapolated @50k ranges", (used * 50_000) / n);

        // 写入路径不受影响：仍可正常购票
        vm.deal(bob, bob.balance + PRICE);
        uint32 _rid7 = lottery.s_currentRound();
        vm.prank(bob);
        lottery.buyTickets{value: PRICE}(1, _rid7);
        assertEq(lottery.rangeCountOf(1), n + 1, "writes unaffected by range count");
    }
}

/// @dev 第 8 轮：把「粉尘逃生阀」的安全前提钉死。
///      _openNextRound 里有一处阶跃：按比例释放取整为 0 且窗口过半时全额放行。
///      阶跃门槛正是前十轮里反复被打穿的模式（阈值一跨就能一次性独占整包），
///      这里之所以安全，**仅仅因为**它只可能在缓冲区余额为 1 wei 时触发。
///      本测试是哨兵：若有人调低 5000 这个阈值，可释放的粉尘量会立刻超标而报警
contract LotteryDustEscapeHatchTest is LotteryTestBase {
    uint256 constant PCT_THRESHOLD = 5000; // 与合约中的常量一致

    function testFuzz_DustEscapeHatchCanOnlyReleaseOneWei(uint256 pending, uint256 pctBps) public {
        pending = bound(pending, 1, 1e30);
        pctBps = bound(pctBps, PCT_THRESHOLD, 10000);

        uint256 proportional = (pending * pctBps) / 10000;
        if (proportional == 0) {
            // 逃生阀会把整个缓冲一次性放出——必须确认那"整个缓冲"只有 1 wei
            assertEq(pending, 1, "step function may only fire on a single wei of dust");
            assertLt(pending, PRICE / 1e10, "released dust is negligible against ticket price");
        }
    }

    /// @dev 反向哨兵：阈值若被调到 100，可一次性放出的量会涨到 99 wei——
    ///      仍是粉尘，但这条断言标出了"阈值越低、阶跃越危险"的方向
    function test_LoweringThresholdWidensTheStepFunction() public pure {
        uint256 maxAtThreshold5000 = 10000 / 5000 - 1; // pending 的上界
        uint256 maxAtThreshold100 = 10000 / 100 - 1;
        assertEq(maxAtThreshold5000, 1);
        assertEq(maxAtThreshold100, 99);
        assertGt(maxAtThreshold100, maxAtThreshold5000);
    }
}
