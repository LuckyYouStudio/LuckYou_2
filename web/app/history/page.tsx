"use client";

// 「我的记录」页（FR-W-03）：历史一律从链上事件重建，不依赖任何后端。
// RPC 对 getLogs 区块范围有限制，因此按区块段分页查询。

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import { isAddress, parseAbiItem, type Address } from "viem";
import {
  ANVIL_ACCOUNTS,
  IS_LOCAL,
  TOKEN,
  addresses,
  fmtToken,
  loadTokenMeta,
  publicClient,
  startBlock,
} from "@/lib/contracts";

const TICKETS_BOUGHT = parseAbiItem(
  "event TicketsBought(uint32 indexed roundId, address indexed buyer, uint32 start, uint32 quantity)",
);
const PRIZE_CLAIMED = parseAbiItem(
  "event PrizeClaimed(uint32 indexed roundId, address indexed winner, uint8 tier, uint256 amount)",
);
// FR-C-29 的弃期退款。不扫这个事件，「累计购票支出」就把已经退回的钱也算成支出，
// 净盈亏因此被系统性低估（第 50 轮 W-3）
const TICKETS_REFUNDED = parseAbiItem(
  "event TicketsRefunded(uint32 indexed roundId, address indexed buyer, uint256 amount)",
);
// Base 公共 RPC（sepolia.base.org / mainnet.base.org）的 eth_getLogs 硬上限是 **2000 块**，
// 超出直接 -32602 "query exceeds max block range 2000"。此处 to = from + BLOCK_CHUNK，
// 单段块数 = BLOCK_CHUNK + 1，故取 1999 恰好贴满 2000。
// 原值 9000 来自「常见 RPC 限制在 1 万块以内」的想当然，对本项目实际使用的端点是错的——
// 部署后距链头不足 2000 块时看不出问题，链一往前走历史页就必然报错（实测确认）
const BLOCK_CHUNK = 1999n;
// 每次打开页面最多扫描的分段数。2000 块/段 × 600 段 = 120 万块 ≈ Base 上 28 天。
// 超出则从链头倒序只扫这么多，并在界面上明说「更早的记录未显示」——
// 宁可诚实地少显示，也不要静默给出不完整的结果（FR-W-03 的历史必须可信）
const MAX_CHUNKS = 600;

const TIER_NAMES = ["一等奖", "二等奖", "三等奖"];

interface BuyRecord {
  roundId: number;
  start: number;
  quantity: number;
  block: bigint;
}

interface ClaimRecord {
  roundId: number;
  tier: number;
  amount: bigint;
  block: bigint;
}

interface RefundRecord {
  roundId: number;
  amount: bigint;
  block: bigint;
}

function fmt6(x: bigint): string {
  return fmtToken(x);
}

export default function History() {
  const [account, setAccount] = useState<string>(IS_LOCAL ? ANVIL_ACCOUNTS[0].address : "");
  const [buys, setBuys] = useState<BuyRecord[]>([]);
  const [claims, setClaims] = useState<ClaimRecord[]>([]);
  const [refunds, setRefunds] = useState<RefundRecord[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // 非 null 表示只扫到了这个区块之后的记录，更早的未显示
  const [truncatedAt, setTruncatedAt] = useState<bigint | null>(null);
  // 地址输入每敲一键就重扫，慢的旧请求可能后返回并覆盖新地址的结果（审计第九轮 M1）
  const reqRef = useRef(0);

  const load = useCallback(async () => {
    const myReq = ++reqRef.current;
    setBuys([]);
    setClaims([]);
    setRefunds([]);
    setTruncatedAt(null);
    if (!isAddress(account)) return;
    setLoading(true);
    setError(null);
    try {
      await loadTokenMeta();
      const latest = await publicClient.getBlockNumber();
      const buyRecords: BuyRecord[] = [];
      const claimRecords: ClaimRecord[] = [];
      const refundRecords: RefundRecord[] = [];

      // 从合约部署块起分段扫描（FR-W-03：仅靠事件重建历史）。
      // 原实现是「两次 getLogs 串行 await、分段也串行」：Base 出块 2 秒 ⇒ 每年约 1576 万块
      // ⇒ 一年后每次打开页面要发约 3500 次串行请求，按公共 RPC 150ms 延迟算 ≈ 9 分钟，
      // 且几乎必然先被限流打断。改为段内两个事件并行 + 分段按 CONCURRENCY 路并发，
      // 把耗时压到约 1/16（R20 L-3）
      const ranges: { from: bigint; to: bigint }[] = [];
      for (let from = startBlock; from <= latest; from += BLOCK_CHUNK + 1n) {
        const to = from + BLOCK_CHUNK > latest ? latest : from + BLOCK_CHUNK;
        ranges.push({ from, to });
      }
      // 链够长时只保留最近的 MAX_CHUNKS 段，并如实告知截断——
      // 全量扫描随链长线性增长，迟早会超时/被限流，届时 catch 只会显示「加载失败」，
      // 那比「显示最近 28 天并说明」更糟（R20 L-3）
      let truncatedFrom: bigint | null = null;
      if (ranges.length > MAX_CHUNKS) {
        truncatedFrom = ranges[ranges.length - MAX_CHUNKS].from;
        ranges.splice(0, ranges.length - MAX_CHUNKS);
      }

      const scanRange = async (r: { from: bigint; to: bigint }) => {
        const [bought, claimed, refunded] = await Promise.all([
          publicClient.getLogs({
            address: addresses.lottery,
            event: TICKETS_BOUGHT,
            args: { buyer: account as Address },
            fromBlock: r.from,
            toBlock: r.to,
          }),
          publicClient.getLogs({
            address: addresses.lottery,
            event: PRIZE_CLAIMED,
            args: { winner: account as Address },
            fromBlock: r.from,
            toBlock: r.to,
          }),
          publicClient.getLogs({
            address: addresses.lottery,
            event: TICKETS_REFUNDED,
            args: { buyer: account as Address },
            fromBlock: r.from,
            toBlock: r.to,
          }),
        ]);
        return { bought, claimed, refunded };
      };

      // 并发度不宜再高：公共 RPC 会限流，超过约 8 路反而更慢
      const CONCURRENCY = 8;
      for (let i = 0; i < ranges.length; i += CONCURRENCY) {
        if (myReq !== reqRef.current) return; // 用户已改查询，立刻停手，别再打 RPC
        const batch = await Promise.all(ranges.slice(i, i + CONCURRENCY).map(scanRange));
        for (const { bought, claimed, refunded } of batch) {
          for (const log of bought) {
            buyRecords.push({
              roundId: Number(log.args.roundId),
              start: Number(log.args.start),
              quantity: Number(log.args.quantity),
              block: log.blockNumber,
            });
          }
          for (const log of claimed) {
            claimRecords.push({
              roundId: Number(log.args.roundId),
              tier: Number(log.args.tier),
              amount: log.args.amount ?? 0n,
              block: log.blockNumber,
            });
          }
          for (const log of refunded) {
            refundRecords.push({
              roundId: Number(log.args.roundId),
              amount: log.args.amount ?? 0n,
              block: log.blockNumber,
            });
          }
        }
      }
      // 并发返回的顺序不保证，按区块号排序后再倒序展示
      buyRecords.sort((a, b) => (a.block < b.block ? -1 : a.block > b.block ? 1 : 0));
      claimRecords.sort((a, b) => (a.block < b.block ? -1 : a.block > b.block ? 1 : 0));
      refundRecords.sort((a, b) => (a.block < b.block ? -1 : a.block > b.block ? 1 : 0));
      if (myReq !== reqRef.current) return; // 已被更新的查询取代，丢弃过期结果
      setBuys(buyRecords.reverse());
      setClaims(claimRecords.reverse());
      setRefunds(refundRecords.reverse());
      setTruncatedAt(truncatedFrom);
    } catch (e) {
      if (myReq !== reqRef.current) return;
      setError((e as Error).message.slice(0, 160));
    } finally {
      if (myReq === reqRef.current) setLoading(false);
    }
  }, [account]);

  useEffect(() => {
    load();
  }, [load]);

  const totalSpent = buys.reduce((s, b) => s + BigInt(b.quantity) * TOKEN.ticketPrice, 0n);
  const totalWon = claims.reduce((s, c) => s + c.amount, 0n);
  const totalRefunded = refunds.reduce((s, r) => s + r.amount, 0n);

  return (
    <main>
      <h1>
        <span>LuckYou</span> 我的记录
      </h1>
      <p className="subtitle">
        <Link href="/" style={{ color: "var(--blue)" }}>
          ← 返回测试台
        </Link>
        {"　"}数据全部来自链上事件（TicketsBought / PrizeClaimed / TicketsRefunded），无后端
      </p>

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="row">
          <span className="k">查询账户</span>
          {IS_LOCAL ? (
            <select value={account} onChange={(e) => setAccount(e.target.value)}>
              {ANVIL_ACCOUNTS.map((a) => (
                <option key={a.address} value={a.address}>
                  {a.name} {a.address.slice(0, 8)}…
                </option>
              ))}
            </select>
          ) : (
            <input
              style={{ width: 340 }}
              placeholder="输入要查询的地址 0x…"
              value={account}
              onChange={(e) => setAccount(e.target.value.trim())}
            />
          )}
        </div>
        <div className="row">
          <span className="k">累计购票支出</span>
          <span className="v">{fmt6(totalSpent)}</span>
        </div>
        <div className="row">
          <span className="k">累计已领奖金</span>
          <span className="v big">{fmt6(totalWon)}</span>
        </div>
        {totalRefunded > 0n && (
          <div className="row">
            <span className="k">累计弃期退款</span>
            <span className="v" title="卡死超 30 天被作废的期，按票款净额原路退回（FR-C-29）">
              {fmt6(totalRefunded)}
            </span>
          </div>
        )}
        {loading && <p style={{ color: "var(--muted)" }}>正在扫描链上事件…</p>}
        {error && <p style={{ color: "var(--red)" }}>加载失败：{error}</p>}
        {truncatedAt !== null && !loading && (
          <p style={{ color: "var(--muted)", fontSize: 12 }}>
            仅显示区块 {truncatedAt.toString()} 之后的记录；更早的记录未扫描（链上数据仍完整）。
          </p>
        )}
      </div>

      <div className="grid">
        <section className="card">
          <h2>购票记录（{buys.length}）</h2>
          <table>
            <thead>
              <tr>
                <th>期号</th>
                <th>票号区间</th>
                <th>张数</th>
                <th>金额</th>
                <th>区块</th>
              </tr>
            </thead>
            <tbody>
              {buys.map((b, i) => (
                <tr key={i}>
                  <td>#{b.roundId}</td>
                  <td>
                    {b.start} ~ {b.start + b.quantity - 1}
                  </td>
                  <td>{b.quantity}</td>
                  <td>{fmt6(BigInt(b.quantity) * TOKEN.ticketPrice)}</td>
                  <td>{b.block.toString()}</td>
                </tr>
              ))}
              {buys.length === 0 && !loading && (
                <tr>
                  <td colSpan={5} style={{ color: "var(--muted)" }}>
                    暂无购票记录
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </section>

        <section className="card">
          <h2>领奖记录（{claims.length}）</h2>
          <table>
            <thead>
              <tr>
                <th>期号</th>
                <th>奖级</th>
                <th>金额</th>
                <th>区块</th>
              </tr>
            </thead>
            <tbody>
              {claims.map((c, i) => (
                <tr key={i}>
                  <td>#{c.roundId}</td>
                  <td>{TIER_NAMES[c.tier] ?? `T${c.tier}`}</td>
                  <td>{fmt6(c.amount)}</td>
                  <td>{c.block.toString()}</td>
                </tr>
              ))}
              {claims.length === 0 && !loading && (
                <tr>
                  <td colSpan={4} style={{ color: "var(--muted)" }}>
                    暂无领奖记录
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </section>
      </div>
    </main>
  );
}
