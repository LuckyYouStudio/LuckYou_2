// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Lottery} from "../src/Lottery.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @title 第 21 轮审计的可执行证据
/// @notice 本文件有两类测试，**都断言「当前实际发生的事」**：
///         1. `test_Poc_*` —— 断言当前的（有问题或至少值得记录的）行为。修复后断言会反转，
///            从而强制回来更新它，而不是悄悄失效。
///         2. `test_Evidence_*` —— 断言「为什么这里没问题」的实证结论（负结果）。
///            它们把「看过了没问题」升级成可复现的事实：一旦某次改动让防线失效，
///            这些测试会立刻变红。
///         对应报告：`docs/audit/AUDIT-2026-08-11-R21.md`

/// @dev 中奖者 + 收款地址是同一个合约：用 `claimTo` 打款给自己，在 receive 里
///      横向重入所有**未加 nonReentrant** 的资金相关入口，逐一记录结果。
///      R20 只测了 `claim`（收款方恒等于中奖人）；`claimTo` 把收款方变成
///      **调用者任选的任意地址**，重入面因此改变，必须重新枚举一遍。
contract ClaimToReenterer {
    Lottery private immutable i_lottery;

    uint32 public target;
    bool public fired;
    bytes public claimErr;
    bytes public claimToErr;
    bytes public withdrawErr;
    bool public buyOk;
    bool public injectOk;
    bool public upkeepOk;
    bool public rolloverOk;
    bool public retryOk;
    uint256 public received;
    uint256 public inboundTransfers;

    constructor(Lottery lottery_) {
        i_lottery = lottery_;
    }

    function buy(uint32 qty) external payable {
        uint32 _rid1 = i_lottery.s_currentRound();
        i_lottery.buyTickets{value: msg.value}(qty, _rid1);
    }

    function attack(uint32 roundId) external {
        target = roundId;
        i_lottery.claimTo(roundId, 0, address(this));
    }

    function claimTier(uint32 roundId, uint8 tier) external {
        i_lottery.claim(roundId, tier);
    }

    receive() external payable {
        received += msg.value;
        inboundTransfers += 1;
        if (fired) return;
        fired = true;

        // ① 受 ReentrancyGuard 保护的三条出金路径：本合约**确实**还有 tier 1 / tier 2
        //    没领，所以若无守卫这两笔就会成功——这才证明守卫真的起了作用
        try i_lottery.claim(target, 1) {}
        catch (bytes memory e) {
            claimErr = e;
        }
        try i_lottery.claimTo(target, 2, address(this)) {}
        catch (bytes memory e) {
            claimToErr = e;
        }
        try i_lottery.withdrawFees() {}
        catch (bytes memory e) {
            withdrawErr = e;
        }

        // ② 未加守卫的入口：逐一试，记录哪些真的能在回调里跑通
        uint32 _rid2 = i_lottery.s_currentRound();
        try i_lottery.buyTickets{value: i_lottery.i_ticketPrice()}(1, _rid2) {
            buyOk = true;
        } catch {}
        try i_lottery.injectPot{value: 1}(i_lottery.s_currentRound()) {
            injectOk = true;
        } catch {}
        try i_lottery.performUpkeep("") {
            upkeepOk = true;
        } catch {}
        try i_lottery.rolloverExpired(target) {
            rolloverOk = true;
        } catch {}
        try i_lottery.retryDraw(target) {
            retryOk = true;
        } catch {}
    }
}

contract AuditR21PocTest is LotteryTestBase {
    uint8[3] private WINNER_COUNTS = [1, 2, 5];

    // =====================================================================
    // 视角 8/10：构造器新加的 anchorTime 闸——它到底有没有把追赶循环真正夹住？
    // =====================================================================

    /// @dev R20 L-4 的修复是 `anchorTime + 365 days >= now`。但闸本身不解决问题——
    ///      要看**闸内最坏配置**的部署成本是否仍在可接受范围。此处直接实测：
    ///      锚点取闸允许的最老值，间隔取合约允许的最小值（6301 秒），
    ///      追赶循环因此跑满 365 天 / 6301 秒 ≈ 5005 圈。
    ///      结论写进报告：闸是**充分**的，L-4 可以结案（而不是只把悬崖挪了个位置）。
    function test_Evidence_AnchorGateBoundsWorstCaseConstructorGas() public {
        uint32[] memory minInterval = new uint32[](1);
        minInterval[0] = uint32(lottery.SEAL_GAP() + lottery.MIN_SALES_WINDOW() + 1); // 6301

        uint64 oldestAllowed = uint64(block.timestamp - 365 days); // 恰好卡在闸上

        uint256 before = gasleft();
        Lottery worst = new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            PRICE,
            oldestAllowed,
            minInterval,
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
        uint256 used = before - gasleft();

        assertEq(worst.s_currentRound(), 1, "worst-case config still deploys");
        // Base 的区块 gas 上限远高于此；这里用一个保守的 30M 作判据
        assertLt(used, 30_000_000, "gate keeps the catch-up loop inside one block");
        emit log_named_uint("worst-case deploy gas at the anchor gate boundary", used);

        // 再老 1 秒就被闸拦下——边界精确，不是"大概"
        vm.expectRevert(Lottery.InvalidSchedule.selector);
        new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            PRICE,
            oldestAllowed - 1,
            minInterval,
            treasury,
            FEE_BPS,
            _tierBps(),
            _tierWinners()
        );
    }

    /// @dev anchorTime 闸**不误伤**合法配置：正式部署脚本取「最近一个已过去的周二 12:00 UTC」，
    ///      距今至多 7 天；即便有人要保留一整年前的历史锚点也照样通过。
    function test_Evidence_AnchorGateDoesNotRejectLegitimateSchedules() public {
        // 2026-08-14（第 50 轮 A-4）：此处原有第四个用例 `block.timestamp + 30 days`，
        // 注释写「闸是单向的，只挡过老」。那个假设是错的——未来锚点会让第 1 期的
        // closeTime 也落在未来，`performUpkeep` 永远不到期、期号永不推进，而实例
        // 照常收钱。它已被改判为非法配置，反向断言见
        // `AuditR50Poc.t.sol::test_RevertWhen_AnchorIsInTheFuture`
        uint64[3] memory legit = [
            uint64(block.timestamp - 7 days), // 部署脚本的实际取值范围
            uint64(block.timestamp - 364 days), // 一年内的历史锚点
            uint64(block.timestamp) // 边界：锚点 == 当刻（快节奏部署分支的取值）
        ];
        for (uint256 i = 0; i < legit.length; i++) {
            Lottery ok = new Lottery(
                address(coordinator),
                subId,
                bytes32(uint256(1)),
                PRICE,
                legit[i],
                _intervals(),
                treasury,
                FEE_BPS,
                _tierBps(),
                _tierWinners()
            );
            assertEq(ok.s_currentRound(), 1, "legitimate anchor must deploy");
        }
    }

    /// @dev `tierBps[i] == 0` 闸同样不误伤：只要每档比例 >= 1 bps、总和 10000、
    ///      slot 总数 <= 16，任何配置都仍然可部署——包括极端的 1 bps 档与 16 档满配。
    function test_Evidence_TierBpsGateDoesNotRejectLegitimateConfigs() public {
        // ① 极小比例的奖级（1 bps）仍然合法
        uint16[] memory tinyBps = new uint16[](2);
        tinyBps[0] = 9999;
        tinyBps[1] = 1;
        uint8[] memory twoWinners = new uint8[](2);
        twoWinners[0] = 1;
        twoWinners[1] = 1;
        Lottery tiny = new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            PRICE,
            ANCHOR,
            _intervals(),
            treasury,
            FEE_BPS,
            tinyBps,
            twoWinners
        );
        assertEq(tiny.s_currentRound(), 1, "1 bps tier is still a legal config");

        // ② slot 预算打满（16 档 x 1 名额）仍然合法
        uint16[] memory maxBps = new uint16[](16);
        uint8[] memory maxWinners = new uint8[](16);
        for (uint256 i = 0; i < 16; i++) {
            maxBps[i] = 625; // 16 x 625 = 10000
            maxWinners[i] = 1;
        }
        Lottery full = new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)),
            PRICE,
            ANCHOR,
            _intervals(),
            treasury,
            FEE_BPS,
            maxBps,
            maxWinners
        );
        assertEq(full.s_currentRound(), 1, "16 slots is still a legal config");
    }

    // =====================================================================
    // 视角 14：外部调用失败模式——performUpkeep 的 try/catch 能否被"gas 饿死"利用？
    // =====================================================================

    /// @dev 假设：任何人都可以用**精确控制的 gas 上限**调 performUpkeep，让内层
    ///      `this.requestRandomWordsSelf()` 因 63/64 规则 OOG 落进 catch，
    ///      于是本期无 VRF 请求、卡在 DRAWING 三小时——一笔 gas 就能给每期加 3 小时延迟。
    ///
    ///      实测结论：**不成立**。要落进 catch 需要
    ///        63/64 x G < cost(VRF 请求)   且   G/64 >= cost(_openNextRound)
    ///      两式蕴含 cost(_openNextRound) <= cost(请求)/63，而实际比值约为 1:1 量级，
    ///      差了近两个数量级。下面对 60 档 gas 上限做扫描：只要外层成功，
    ///      requestId 必然已登记。
    function test_Evidence_GasStarvedPerformUpkeepCannotSkipTheVrfRequest() public {
        _buy(alice, 10);
        vm.warp(_drawTimeOf(1));

        uint256 succeeded = 0;
        for (uint256 g = 30_000; g <= 620_000; g += 10_000) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(lottery).call{gas: g}(
                abi.encodeWithSelector(Lottery.performUpkeep.selector, bytes(""))
            );
            if (ok) {
                (uint256 requestId,) = lottery.vrfRequestOf(1);
                assertGt(requestId, 0, "outer success must imply a registered VRF request");
                assertEq(lottery.s_currentRound(), 2, "and the next round must have opened");
                succeeded++;
            }
            vm.revertToState(snap);
        }
        assertGt(succeeded, 0, "the sweep must actually reach the succeeding region");
    }

    // =====================================================================
    // 视角 3：claimTo 引入的新重入面（R20 M-1 的修复是本轮的重点复查对象）
    // =====================================================================

    /// @dev claimTo 让**收款地址由调用者任选**，派奖回调因此不再必然落在中奖人身上。
    ///      本测试把中奖人与收款地址做成同一个恶意合约，在 receive 里横向重入
    ///      全部资金相关入口，逐条记录结果，并在事后校验偿付性恒等式。
    ///      结论：三条出金路径都被 ReentrancyGuard 挡下；buyTickets / injectPot
    ///      在回调里**确实可以跑通**，但它们是付钱进来的方向，无害。
    function test_Evidence_ClaimToDoesNotOpenACrossFunctionReentrancyPath() public {
        ClaimToReenterer evil = new ClaimToReenterer(lottery);
        uint256 cost = PRICE * 10;
        vm.deal(address(evil), cost + 1 ether); // 额外 1 ETH 供回调里的横向调用花费
        evil.buy{value: cost}(10); // 买光全场 => 必中全部奖级

        _settleRound(1, 42);

        uint256 per0 = lottery.perWinnerAmount(1, 0);
        uint256 per1 = lottery.perWinnerAmount(1, 1);
        uint256 per2 = lottery.perWinnerAmount(1, 2);
        assertGt(per0, 0);
        assertGt(per1, 0);
        assertGt(per2, 0);

        evil.attack(1);

        // ① 出金路径全部被守卫拦下
        assertEq(
            bytes4(evil.claimErr()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "reentrant claim must be blocked"
        );
        assertEq(
            bytes4(evil.claimToErr()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "reentrant claimTo must be blocked"
        );
        assertEq(
            bytes4(evil.withdrawErr()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "reentrant withdrawFees must be blocked"
        );

        // ② 未加守卫的入口：只有「往合约里付钱」的两条能跑通，其余被状态机自然拒绝
        assertTrue(
            evil.buyOk(), "buyTickets is reachable from the payout callback (inbound, harmless)"
        );
        assertTrue(
            evil.injectOk(), "injectPot is reachable from the payout callback (inbound, harmless)"
        );
        assertFalse(evil.upkeepOk(), "performUpkeep rejected: next round is not due");
        assertFalse(evil.rolloverOk(), "rolloverExpired rejected: claim window still open");
        assertFalse(evil.retryOk(), "retryDraw rejected: round already SETTLED");

        // ③ 一等奖只付了一次
        assertEq(evil.inboundTransfers(), 1, "exactly one payout landed");
        assertEq(evil.received(), per0, "and it was exactly one tier-1 share");

        // ④ 剩下的奖级事后仍可正常领取，账不多不少
        evil.claimTier(1, 1);
        evil.claimTier(1, 2);
        assertEq(evil.received(), per0 + per1 * 2 + per2 * 5, "no double pay, no shortfall");

        // ⑤ 偿付性恒等式在这一切之后仍然成立
        assertEq(address(lottery).balance, _obligations(), "solvency identity holds");
    }

    /// @dev claimTo 不能把奖金塞回彩票合约自己（合约无 receive/fallback）：
    ///      否则「余额 == 债务」这条恒等式会被一笔无主的入账打破。
    function test_Evidence_ClaimToCannotPushPrizeBackIntoTheLottery() public {
        _buy(alice, 10);
        _settleRound(1, 42);

        vm.prank(alice);
        vm.expectRevert(Lottery.TransferFailed.selector);
        lottery.claimTo(1, 0, address(lottery));

        // 失败后奖金原封不动，仍可正常领走
        uint256 before = alice.balance;
        vm.prank(alice);
        lottery.claim(1, 0);
        assertEq(alice.balance - before, lottery.perWinnerAmount(1, 0));
    }

    /// @dev claimTo 的 `PrizeClaimed` 记的是**中奖人**（msg.sender），不是收款地址。
    ///      这是刻意的（NatSpec 有写），但意味着纯事件重建器算出的「某地址累计已领奖金」
    ///      是**归属额**而非**到账额**——前端 history 页正是这么用的。此处把语义钉死。
    function test_Poc_ClaimToEventNamesTheHolderNotTheRecipient() public {
        _buy(alice, 10);
        _settleRound(1, 42);
        uint256 prize = lottery.perWinnerAmount(1, 0);

        vm.expectEmit(true, true, false, true, address(lottery));
        emit Lottery.PrizeClaimed(1, alice, 0, prize);
        vm.prank(alice);
        lottery.claimTo(1, 0, carol); // 钱进 carol，事件写 alice

        assertEq(carol.balance, prize, "funds went to the recipient");
    }

    // =====================================================================
    // 视角 4/11：暂停快照与 injectPot 的不对称
    // =====================================================================

    /// @dev `buyTickets` 看开期快照 `salesPausedAtOpen`，`injectPot` **不看**。
    ///      于是在全局暂停期间，任何人仍可向一个**注定卖不出任何一张票、注定 VOID**
    ///      的期注资；这笔钱随后在「VOID -> 缓冲 -> 新期（同样被暂停）-> VOID」之间
    ///      无限循环，只要暂停不解除就没有任何人能碰到它。钱不会丢，但注资人
    ///      得不到任何对价，而 FR-C-26 明确「注入只进不出」。这是一个真实的不对称。
    /// @dev R21 C-1 已修复（2026-08-15）。原 PoC 断言的是修复**前**的坏行为：
    ///      暂停期照收注资。此处改为钉住修复后的性质，并保留当初判定它值得修的证据链——
    ///      暂停快照在开期时定死，被暂停的期**永远不可能有票**（事后恢复也改不了本期快照），
    ///      必然零票 VOID，因此注进去的钱必然落入滚存缓冲区，而缓冲区没有退出通道
    ///      （FR-C-28）。缺了这道闸，injectPot 就是一条把资金单向送进黑洞的合法入口。
    function test_Fix_InjectPotHonorsTheSalesPauseSnapshot() public {
        // 让下一期在"已暂停"状态下开出
        lottery.setSalesPaused(true);
        _buy(alice, 1); // 第 1 期是暂停生效前开出的，仍可购票
        _settleRound(1, 7);

        uint32 paused = lottery.s_currentRound();
        assertFalse(lottery.salesOpenFor(paused), "the new round opened paused");

        // 购票被拒
        vm.deal(bob, bob.balance + PRICE);
        uint32 _rid3 = lottery.s_currentRound();
        vm.prank(bob);
        vm.expectRevert(Lottery.SalesArePaused.selector);
        lottery.buyTickets{value: PRICE}(1, _rid3);

        // 修复点：注资也被同一道闸拒绝，钱根本进不来
        uint256 potBefore = _potOf(paused);
        vm.deal(carol, carol.balance + 5 ether);
        vm.prank(carol);
        vm.expectRevert(Lottery.SalesArePaused.selector);
        lottery.injectPot{value: 5 ether}(paused);
        assertEq(_potOf(paused), potBefore, "the paused round's pot is untouched");

        // 证据链：这一期确实必然零票 VOID —— 也就是说，钱只要进得来就一定被困住
        _triggerDraw(paused);
        assertEq(uint8(_stateOf(paused)), uint8(Lottery.RoundState.VOIDED));

        // 反向守卫：别把闸开过头。恢复售票后新开的期必须照常接受注资
        lottery.setSalesPaused(false);
        uint32 stillPaused = lottery.s_currentRound(); // 它是暂停期间开出的，快照仍为 true
        _triggerDraw(stillPaused);
        uint32 live = lottery.s_currentRound();
        assertTrue(lottery.salesOpenFor(live), "a round opened after unpausing sells normally");
        _inject(carol, live, 5 ether);
        assertGe(_potOf(live), 5 ether, "injection still works where it is actually playable");

        assertEq(address(lottery).balance, _obligations(), "solvency holds");
    }

    // =====================================================================
    // 视角 9：R20 I-3（_ownerOfTicket 空数组下溢）到底可不可达
    // =====================================================================

    /// @dev I-3 只写了注释，没有测试把前置条件钉住。此处对一个**零 range 的期**
    ///      枚举所有可能走到 `_ownerOfTicket` 的外部视图，证明每一条都在到达
    ///      `ranges.length - 1` 之前被拦住（而不是靠运气）。
    function test_Evidence_EmptyRangeRoundCannotReachTheBinarySearch() public {
        _triggerDraw(1); // 第 1 期零购票 => VOIDED，s_ranges[1] 长度为 0
        assertEq(uint8(_stateOf(1)), uint8(Lottery.RoundState.VOIDED));
        assertEq(lottery.rangeCountOf(1), 0, "no ranges at all");

        // ① ownerOfTicket：被 ticketId >= ticketCount 拦下（ticketCount = 0 => 任何 id 都拦）
        vm.expectRevert(Lottery.TicketOutOfRange.selector);
        lottery.ownerOfTicket(1, 0);
        vm.expectRevert(Lottery.TicketOutOfRange.selector);
        lottery.ownerOfTicket(1, type(uint32).max);

        // ② winnersOf：被 state != SETTLED 拦下
        vm.expectRevert(Lottery.RoundNotSettled.selector);
        lottery.winnersOf(1);

        // ③ pendingPrizes：同样被 state 闸拦下，安全返回全零而不是 panic
        uint256[] memory amounts = lottery.pendingPrizes(1, alice);
        for (uint256 i = 0; i < amounts.length; i++) {
            assertEq(amounts[i], 0, "pendingPrizes returns zeros, never panics");
        }

        // ④ claim / claimTo：被 state 闸拦下
        vm.prank(alice);
        vm.expectRevert(Lottery.RoundNotSettled.selector);
        lottery.claim(1, 0);
        vm.prank(alice);
        vm.expectRevert(Lottery.RoundNotSettled.selector);
        lottery.claimTo(1, 0, alice);
    }

    // =====================================================================
    // 视角 2/8：结算分账的零泄漏——用 fuzz 把 R20 的手工推导变成可复现事实
    // =====================================================================

    /// @dev 对任意（自售额，注资额）组合，结算必须严格满足
    ///          结算前 pot + tier1Carry  ==  实际派出的奖金总额 + 缓冲区净增量
    ///      三处取整（比例切分余数、均分余数、未开出奖级）都必须并入缓冲，
    ///      一 wei 都不能凭空消失或凭空出现。
    function testFuzz_Evidence_SettlementConservesEveryWei(uint32 qty, uint96 injection) public {
        qty = uint32(bound(qty, 1, 1000));
        uint256 inject = bound(injection, 1, 50 ether);

        _buy(alice, qty);
        _inject(carol, 1, inject);

        uint256 potBefore = _potOf(1);
        uint256 tier1Before = _carryOf(1);
        uint256 bufPotBefore = lottery.s_pendingPot();
        uint256 bufTier1Before = lottery.s_pendingTier1();

        _settleRound(1, uint256(keccak256(abi.encode(qty, inject))));

        uint256 distributed = 0;
        for (uint8 t = 0; t < 3; t++) {
            uint256 per = lottery.perWinnerAmount(1, t);
            if (per > 0) distributed += per * WINNER_COUNTS[t];
        }
        uint256 bufferDelta =
            (lottery.s_pendingPot() - bufPotBefore) + (lottery.s_pendingTier1() - bufTier1Before);

        assertEq(
            potBefore + tier1Before, distributed + bufferDelta, "settlement leaks or mints wei"
        );
        assertEq(address(lottery).balance, _obligations(), "solvency identity holds after settle");
    }

    // =====================================================================
    // 视角 14：treasury 被配成彩票自身——「无 receive/fallback」这条设计是否真的兜住了
    // =====================================================================

    /// @dev 若 `_sendValue(address(this), fees)` 能成功，`s_accruedFees` 会被清零
    ///      而余额纹丝不动 => 债务凭空减少一笔，偿付性恒等式（余额 == 债务）被打破，
    ///      这笔"无主余额"此后只能被下一次 rollover/claim 随机吞掉。
    ///      实测：合约没有 receive/fallback（FR-C-03），call 失败 => 整笔回滚，
    ///      抽成一分不少。这条设计**是**承重墙，不只是防误转。
    function test_Evidence_TreasurySetToTheLotteryCannotBreakSolvency() public {
        _buy(alice, 100);
        uint256 feesBefore = lottery.s_accruedFees();
        assertGt(feesBefore, 0);

        lottery.setTreasury(address(lottery)); // owner 的合法调用，零地址闸挡不住

        vm.expectRevert(Lottery.TransferFailed.selector);
        lottery.withdrawFees();

        assertEq(lottery.s_accruedFees(), feesBefore, "fees untouched after the failed transfer");
        assertEq(address(lottery).balance, _obligations(), "solvency identity holds");

        // 改回可收款地址即可解冻（FR-C-22 声称的自救路径，此处实测确认）。
        // 2026-08-14（第 50 轮 A-1）：`withdrawFees` 现在会为当期的开奖奖励留一份，
        // 因此「全部解冻」的判据从 `feesBefore` 改为 `withdrawableFees()`——
        // 留下的那一份不是卡住的钱，它会在该期开出时发给触发者
        lottery.setTreasury(treasury);
        uint256 withdrawable = lottery.withdrawableFees();
        assertGt(withdrawable, 0);
        lottery.withdrawFees();
        assertEq(treasury.balance, withdrawable, "fees recovered");
        assertEq(lottery.s_accruedFees(), feesBefore - withdrawable, "only the reserve remains");
    }

    // =====================================================================
    // 视角 17：假阳性测试——断言了，但从没跑到它自称在守的那条路径
    // =====================================================================
    //
    // 共同的根因：日程是 [2d, 3d, 2d] 循环，`s_intervalCursor` 在**开期时**推进，
    // 所以「第 N 期之后的下一个场次」并不总是 closeTime(N) + 2 days。
    // 三个测试都按「+2 天」（或「+3 天」）硬算下一场次，结果 warp 到了一个
    // 距真实场次还有整整一天的时刻，于是它们要守的边界条件根本没被触发。

    /// @dev FP-1：`LotteryFieldControl.test_SalesWindowCannotBeSnipedShort`
    ///      自称「攻击者卡在距下一场次仅 1 秒时触发」，实测它拿到的是**一整天**的窗口。
    ///      `assertGe(window, MIN_SALES_WINDOW)` 因此恒真——把 `_openNextRound` 的
    ///      do-while 换成朴素的 `while (t <= block.timestamp)`，这条测试照样绿。
    function test_Poc_WindowSnipeRegressionNeverReachesTheGuardItGuards() public {
        _buy(alice, 10);
        // 现有测试的 warp 点：closeTime(1) + 2 days
        uint64 assumedNextSlot = _closeTimeOf(1) + 2 days;
        // 但第 1 期开期时 cursor 已推进到 1，下一场次由 intervals[1] = 3 days 决定
        assertEq(
            _closeTimeOf(1) + 3 days, ANCHOR + 5 days, "the real next slot is a 3-day leg away"
        );
        assertTrue(assumedNextSlot < ANCHOR + 5 days, "the test warps a full day too early");

        vm.warp(uint256(assumedNextSlot) - 1);
        lottery.performUpkeep("");

        uint32 opened = lottery.s_currentRound();
        uint64 window = _closeTimeOf(opened) - uint64(block.timestamp);
        assertEq(window, 1 days + 1, "the 'sniped' window is a full day, not seconds");
        assertGt(
            window, lottery.MIN_SALES_WINDOW() * 40, "so the floor assertion is trivially satisfied"
        );
    }

    /// @dev 同一场景**正确**复现后，最短窗口这道闸确实有效——这是那条测试本该断言的东西。
    function test_Evidence_RealWindowSnipeIsBlockedByMinSalesWindow() public {
        _buy(alice, 10);
        uint64 realNextSlot = _closeTimeOf(1) + 3 days; // intervals[1]
        vm.warp(uint256(realNextSlot) - 1);
        lottery.performUpkeep("");

        uint32 opened = lottery.s_currentRound();
        uint64 window = _closeTimeOf(opened) - uint64(block.timestamp);
        assertGe(window, lottery.MIN_SALES_WINDOW(), "floor holds when the scenario is real");
        // 而且是靠**跳过**这个近在眼前的场次实现的（do-while 的目的）
        assertEq(_closeTimeOf(opened), realNextSlot + 2 days, "the imminent slot was skipped");
    }

    /// @dev FP-2：`LotteryWindowProRata.test_LongNominalWindowStillReleases` 是为
    ///      第四轮复查 M-1（释放比例用百分比整数除法会归零）加的回归。但它同样按
    ///      「+3 天」硬算场次，实际落到一个**跨两腿、名义 4 天、实际窗口 1 天**的组合，
    ///      百分比公式在这里算出 25%（不是 0），所以**有 bug 的旧实现也会让它通过**。
    function test_Poc_ProRataRegressionDoesNotReproduceThePercentZeroCase() public {
        _buy(alice, 3);
        _settleRound(1, 7);
        uint32 r = lottery.s_currentRound(); // 第 2 期，closeTime = ANCHOR + 5d
        _buy(bob, 10);

        uint64 prevSlot = _closeTimeOf(r);
        uint64 assumedNextSlot = prevSlot + 3 days; // 现有测试的假设
        assertEq(prevSlot + 2 days, ANCHOR + 7 days, "the real next slot is a 2-day leg away");

        uint256 warpTo = uint256(assumedNextSlot) - lottery.MIN_SALES_WINDOW() - 1;
        vm.warp(warpTo);
        lottery.performUpkeep("");

        uint64 openedClose = _closeTimeOf(lottery.s_currentRound());
        uint256 nominal = uint256(openedClose) - (uint256(prevSlot) + 75 minutes);
        uint256 actual = uint256(openedClose) - warpTo;
        // 有 bug 的旧公式（百分比整数除法）在这里给出 25%，远不是 0——测不出它要测的东西
        assertEq((actual * 100) / nominal, 25, "the buggy percent formula would also pass");
    }

    /// @dev 正确复现 M-1 的场景：让释放落在**真正的 3 天腿**上并把实际窗口压到下限。
    ///      此时百分比公式给出 0（缓冲被冻死），而现行的 bps 公式给出 70 bps 仍有释放——
    ///      这才是那条回归测试该有的形状。
    function test_Evidence_BpsPrecisionIsLoadBearingOnTheThreeDayLeg() public {
        _inject(carol, 1, 10 ether); // 第 1 期零购票 => VOID，10 ETH 进缓冲
        uint64 threeDayLegSlot = _closeTimeOf(1) + 3 days; // intervals[1]

        uint256 warpTo = uint256(threeDayLegSlot) - lottery.MIN_SALES_WINDOW() - 1;
        vm.warp(warpTo);
        lottery.performUpkeep(""); // VOID 第 1 期并开出第 2 期

        uint32 opened = lottery.s_currentRound();
        uint256 nominal = uint256(_closeTimeOf(opened)) - (uint256(_closeTimeOf(1)) + 75 minutes);
        uint256 actual = uint256(_closeTimeOf(opened)) - warpTo;

        assertEq((actual * 100) / nominal, 0, "percent formula rounds to zero => frozen buffer");
        assertEq((actual * 10000) / nominal, 70, "bps formula keeps 70 bps alive");
        assertGt(_potOf(opened), 0, "and the buffer really does keep flowing");
        assertEq(_potOf(opened), (10 ether * 70) / 10000, "released exactly the pro-rata share");
    }

    /// @dev FP-3：`LotteryCarryTiming.test_UnopenedTierCarryBuffered` 的最后一句
    ///      `assertEq(perWinnerAmount(3, 0), 0)` 是**空断言**——第 3 期还没结算，
    ///      任何奖级的 perWinner 都必然是 0，与「上期 carry 是否并入第 3 期一等奖」无关。
    ///      它上面的注释描述的才是该做的检查。此处补上真正的断言。
    function test_Poc_UnopenedTierCarryTestHasAVacuousFinalAssertion() public {
        _buy(alice, 3); // 三等奖（5 名）不开出 => 15% 滚存
        _settleRound(1, 7);
        assertEq(lottery.s_pendingTier1(), 44_550_000_000_000, "unopened-tier carry buffered");

        _buy(bob, 10);
        _settleRound(2, 8); // 开出第 3 期时消费缓冲

        // 现有测试断言的东西：第 3 期未结算，所有奖级都是 0 —— 与 carry 无关，恒真
        assertEq(lottery.perWinnerAmount(3, 0), 0, "vacuous: round 3 is OPEN, not SETTLED");
        assertEq(lottery.perWinnerAmount(3, 1), 0, "same holds for every other tier");
        assertEq(lottery.perWinnerAmount(3, 2), 0, "so this assertion proves nothing about carry");

        // 真正该断言的：carry 确实落进了第 3 期的一等奖份额
        assertEq(_carryOf(3), 44_550_000_000_000, "the carry actually landed in round 3 tier-1");
    }

    // =====================================================================
    // helper
    // =====================================================================

    /// @dev 全部在库债务：抽成 + 缓冲区 + 未开奖期的 pot/tier1 + 已结算期的未领奖金。
    ///      与 LotteryInvariant 的口径一致，用于单点校验偿付性恒等式。
    function _obligations() internal view returns (uint256 total) {
        // FR-C-30（2026-08-13 增）：已记账未领取的开奖奖励也是应付义务。
        // 它是从 s_accruedFees 里挪出来的——漏掉这一项会把「换了口袋」误判成「资金泄漏」
        total = lottery.s_accruedFees() + lottery.s_pendingPot() + lottery.s_pendingTier1()
            + lottery.s_pendingKeeperRewards();
        uint32 cur = lottery.s_currentRound();
        for (uint32 id = 1; id <= cur; id++) {
            (Lottery.RoundState st,,,, uint256 pot, uint256 carry,, uint16 bits,) =
                lottery.getRound(id);
            if (st == Lottery.RoundState.OPEN || st == Lottery.RoundState.DRAWING) {
                total += pot + carry;
            } else if (st == Lottery.RoundState.SETTLED) {
                uint8 slot = 0;
                for (uint8 t = 0; t < 3; t++) {
                    uint256 per = lottery.perWinnerAmount(id, t);
                    for (uint8 j = 0; j < WINNER_COUNTS[t]; j++) {
                        if (per > 0 && bits & (uint16(1) << slot) == 0) total += per;
                        slot++;
                    }
                }
            }
        }
    }
}
