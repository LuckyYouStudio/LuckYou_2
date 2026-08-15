// 多期验证观察器（FR-T-05）
//
// 为什么需要它：Foundry 的不变量测试跑的是 mock —— mock 的 VRF 立刻回调、gas 无限、
// 时间由 vm.warp 说了算。链上那些恰恰是最容易出事的地方（VRF 回调有 gas 上限，
// 回调里静默失败会让整期卡在 DRAWING，这是 CLAUDE.md 里已经记下的坑）。
// 所以多期验证要有一份**独立于合约自身账本**的复核。
//
// 独立性是这个脚本的全部价值所在：它**只读事件和链上余额**，绝不调用合约的
// s_accruedFees / getRound 之类的 getter 来做判定 —— 拿合约自己的账本去验它自己的
// 余额是循环论证，账本算错时两边会一起错，对得严丝合缝。
//
// 用法：node scripts/observe.mjs [--json]

import { createPublicClient, http, parseAbiItem, formatEther } from "viem";
import { baseSepolia } from "viem/chains";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const dep = JSON.parse(readFileSync(join(here, "../src/lib/deployment.base-sepolia.json"), "utf8"));
// 可指向任意历史实例：既方便回看旧实例，也是这个脚本的自检手段——
// 只会打印 0 的检查器等于没有检查器，必须拿真跑过多期的实例验一遍它认得出活动
if (process.env.LOTTERY) dep.lottery = process.env.LOTTERY;
if (process.env.START_BLOCK) dep.startBlock = Number(process.env.START_BLOCK);

const RPC = process.env.RPC_URL ?? "https://base-sepolia-rpc.publicnode.com";
// Base 公共 RPC 的 eth_getLogs 硬上限是 2000 块。踩过一次，别再改大
const CHUNK = 1999n;

// 事件签名**从 ABI 直接取**，不手写。
// 手写过一次就知道为什么：DrawSettled 的真实签名是
// (roundId, seed, ticketCount, perWinnerAmounts)，我按印象写成了
// (roundId, randomWord, winningTickets) —— topic0 于是对不上，那个事件被静默漏掉，
// 观察器据此报告「第 1 期卡在 DRAWING」。而同一份数据里明明有人领走了奖金，
// DRAWING 状态根本领不了奖。是这个自相矛盾把错误暴露出来的，不是签名本身。
// 从 ABI 取则永远不会和合约脱节。
const ABI = JSON.parse(readFileSync(join(here, "../src/lib/abi/Lottery.json"), "utf8"));
const EVENTS = ABI.filter((x) => x.type === "event");

const client = createPublicClient({ chain: baseSepolia, transport: http(RPC) });

async function fetchAll() {
  const latest = await client.getBlockNumber();
  const out = [];
  const ranges = [];
  for (let f = BigInt(dep.startBlock); f <= latest; f += CHUNK + 1n) {
    ranges.push({ from: f, to: f + CHUNK > latest ? latest : f + CHUNK });
  }
  for (let i = 0; i < ranges.length; i += 8) {
    const batch = await Promise.all(
      ranges.slice(i, i + 8).map((r) =>
        client.getLogs({ address: dep.lottery, events: EVENTS, fromBlock: r.from, toBlock: r.to }),
      ),
    );
    for (const logs of batch) out.push(...logs);
  }
  out.sort((a, b) =>
    a.blockNumber === b.blockNumber
      ? a.logIndex - b.logIndex
      : a.blockNumber < b.blockNumber
        ? -1
        : 1,
  );
  return { logs: out, latest };
}

const eth = (x) => `${formatEther(x)} ETH`;

async function main() {
  const price = await client.readContract({
    address: dep.lottery,
    abi: [parseAbiItem("function i_ticketPrice() view returns (uint256)")],
    functionName: "i_ticketPrice",
  });
  const { logs, latest } = await fetchAll();
  const balance = await client.getBalance({ address: dep.lottery });

  // ---- 资金守恒：只有两个 payable 入口，四条出账路径 ----
  let inTickets = 0n, inInject = 0n;
  let outPrize = 0n, outFees = 0n, outKeeper = 0n, outRefund = 0n;
  const rounds = new Map();
  const R = (id) => {
    if (!rounds.has(id))
      rounds.set(id, {
        id, tickets: 0, bought: 0n, injected: 0n, claimed: 0n, keeperReward: 0n,
        carryIn: 0n, withheld: 0n, opened: null, requested: null, settled: null,
        state: "OPEN", winners: null,
      });
    return rounds.get(id);
  };
  const blockTime = new Map();
  const problems = [];
  const notes = [];

  for (const l of logs) {
    const a = l.args;
    const rid = a.roundId !== undefined ? Number(a.roundId) : undefined;
    switch (l.eventName) {
      case "RoundOpened": R(rid).opened = l.blockNumber; blockTime.set(rid, Number(a.closeTime)); break;
      case "TicketsBought": {
        const amt = BigInt(a.quantity) * price;
        inTickets += amt; R(rid).tickets += Number(a.quantity); R(rid).bought += amt; break;
      }
      case "PotInjected": inInject += a.amount; R(rid).injected += a.amount; break;
      case "DrawRequested": R(rid).requested = l.blockNumber; R(rid).state = "DRAWING"; break;
      case "DrawSettled": R(rid).settled = l.blockNumber; R(rid).state = "SETTLED"; R(rid).winners = a.perWinnerAmounts; break;
      case "PrizeClaimed": outPrize += a.amount; R(rid).claimed += a.amount; break;
      case "CarryReleased": R(Number(a.toRound)).carryIn += a.potAmount + a.tier1Amount; break;
      case "CarryWithheld": R(rid).withheld += a.amount; break;
      case "RoundVoided": R(rid).state = "VOIDED"; break;
      case "RoundAbandoned": R(rid).state = "ABANDONED"; break;
      case "FeesWithdrawn": outFees += a.amount; break;
      case "KeeperRewarded": R(rid).keeperReward += a.amount; break;
      case "KeeperRewardClaimed": outKeeper += a.amount; break;
      case "TicketsRefunded": outRefund += a.amount; break;
      case "DrawRequestFailed":
        problems.push(`第 ${rid} 期 DrawRequestFailed —— VRF 订阅多半没 LINK 了`); break;
    }
  }

  const expected = inTickets + inInject - outPrize - outFees - outKeeper - outRefund;
  const drift = balance - expected;

  console.log(`\n=== LuckYou 多期验证观察器 ===`);
  console.log(`Lottery  ${dep.lottery}`);
  console.log(`扫描区块 ${dep.startBlock} → ${latest}（${logs.length} 条事件）\n`);

  console.log(`--- 资金守恒（只用事件推算，不读合约账本）---`);
  console.log(`  入：购票 ${eth(inTickets)}  注资 ${eth(inInject)}`);
  console.log(`  出：奖金 ${eth(outPrize)}  抽成 ${eth(outFees)}  开奖奖励 ${eth(outKeeper)}  退款 ${eth(outRefund)}`);
  console.log(`  事件推算应有余额 ${eth(expected)}`);
  console.log(`  链上实际余额     ${eth(balance)}`);
  if (drift === 0n) console.log(`  ✅ 完全一致\n`);
  else if (drift > 0n) {
    console.log(`  ⚠️ 多出 ${eth(drift)}`);
    notes.push(`余额比事件推算多 ${eth(drift)}。合约没有 receive/fallback，正常路径进不来，可能是 selfdestruct 强塞。不影响偿付，但这笔钱谁也取不走`);
  } else {
    console.log(`  ❌ 少了 ${eth(-drift)}`);
    problems.push(`余额比事件推算少 ${eth(-drift)} —— 存在未被事件记录的出账路径，这是严重问题`);
  }

  // ---- VRF 活性：每个 DrawRequested 都必须等到 DrawSettled ----
  const ids = [...rounds.keys()].sort((a, b) => a - b);
  let stuck = 0, settledCount = 0;
  for (const id of ids) {
    const r = rounds.get(id);
    if (r.requested && !r.settled) { stuck++; problems.push(`第 ${id} 期卡在 DRAWING（有 DrawRequested 无 DrawSettled）`); }
    if (r.settled) settledCount++;
  }
  console.log(`--- VRF 活性 ---`);
  console.log(`  已结算 ${settledCount} 期，卡死 ${stuck} 期`);
  if (settledCount === 0) notes.push("还没有任何一期结算，VRF 回调路径在链上仍未被验证");

  // ---- 日程推进 ----
  // 注意：间隔**不要求相等**。开奖迟到时 _advanceSlot 会一路跳到下一个还来得及售票的
  // 场次，所以间隔天然是「间隔的整数倍」。把它当成等距去查会在验证期不停误报，
  // 而误报比不查更糟——它会训练你忽略这一栏。
  // 真正有价值的信号是倍数本身：倍数 > 1 就说明那一期的开奖迟到到跳过了场次，
  // 这正是 keeper 准时度的直接度量。
  // （s_intervals 是 private 且无 getter，链上读不到，所以由外部显式给出）
  const INTERVAL = Number(process.env.INTERVAL_SECONDS ?? 7200);
  let skipped = 0, maxMult = 1;
  for (let i = 1; i < ids.length; i++) {
    if (ids[i] !== ids[i - 1] + 1) problems.push(`期号不连续：${ids[i - 1]} 之后直接是 ${ids[i]}`);
    const a = blockTime.get(ids[i - 1]), b = blockTime.get(ids[i]);
    if (!a || !b) continue;
    const gap = b - a;
    if (gap % INTERVAL !== 0)
      problems.push(`第 ${ids[i - 1]}→${ids[i]} 期停售间隔 ${gap} 秒不是 ${INTERVAL} 的整数倍 —— 日程推进逻辑异常`);
    const mult = gap / INTERVAL;
    if (mult > 1) { skipped++; maxMult = Math.max(maxMult, mult); }
  }
  console.log(`--- 日程推进（间隔基准 ${INTERVAL} 秒）---`);
  console.log(`  期号连续 ${ids.length} 期；开奖迟到导致跳过场次的有 ${skipped} 次${skipped ? `，最严重一次跳了 ${maxMult} 个场次` : ""}`);
  if (skipped && ids.length > 2)
    notes.push(`${skipped} 次开奖迟到到跳过了场次 —— 这是 keeper 准时度问题，不是合约问题，但会拉长验证周期`);

  // ---- 从未在链上验证过的路径 ----
  const carryRounds = ids.filter((i) => rounds.get(i).carryIn > 0n);
  const keeperRounds = ids.filter((i) => rounds.get(i).keeperReward > 0n);
  console.log(`\n--- 关键路径链上覆盖 ---`);
  console.log(`  跨期滚存释放 CarryReleased：${carryRounds.length ? `✅ ${carryRounds.length} 次（期 ${carryRounds.join(",")}）` : "❌ 从未发生"}`);
  console.log(`  开奖激励 KeeperRewarded：  ${keeperRounds.length ? `✅ ${keeperRounds.length} 次` : "❌ 从未发生"}`);
  console.log(`  弃期退款 TicketsRefunded： ${outRefund > 0n ? `✅ ${eth(outRefund)}` : "— 未发生（正常）"}`);
  if (!carryRounds.length) notes.push("CarryReleased 仍未在链上跑过 —— 这是滚存逻辑最复杂的一段，多期验证的首要目标");

  // ---- FR-C-30 上限：单期奖励不得超过一张票价 ----
  for (const id of keeperRounds) {
    const r = rounds.get(id);
    if (r.keeperReward > price)
      problems.push(`第 ${id} 期开奖奖励 ${eth(r.keeperReward)} 超过一张票价 ${eth(price)}（FR-C-30 硬上限被突破）`);
  }

  // ---- 逐期明细 ----
  console.log(`\n--- 逐期明细 ---`);
  console.log(`  期  状态       票数   购票额        滚入        扣留        开奖奖励      已领奖`);
  for (const id of ids) {
    const r = rounds.get(id);
    const p = (s, n) => String(s).padEnd(n);
    console.log(
      `  ${p(id, 4)}${p(r.state, 11)}${p(r.tickets, 7)}${p(formatEther(r.bought), 14)}` +
      `${p(formatEther(r.carryIn), 12)}${p(formatEther(r.withheld), 12)}` +
      `${p(formatEther(r.keeperReward), 14)}${formatEther(r.claimed)}`,
    );
  }

  console.log(`\n--- 结论 ---`);
  if (problems.length) { console.log(`  ❌ ${problems.length} 个问题：`); problems.forEach((p) => console.log(`     · ${p}`)); }
  else console.log(`  ✅ 未发现不一致`);
  if (notes.length) { console.log(`  ℹ️ 待补验证：`); notes.forEach((n) => console.log(`     · ${n}`)); }
  console.log();

  if (process.argv.includes("--json")) {
    console.log(JSON.stringify({ balance: balance.toString(), expected: expected.toString(), drift: drift.toString(), problems, notes }, null, 2));
  }
  process.exitCode = problems.length ? 1 : 0;
}

main().catch((e) => { console.error("观察器失败：", e.message); process.exitCode = 2; });
