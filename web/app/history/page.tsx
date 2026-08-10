"use client";

// 「我的记录」页（FR-W-03）：历史一律从链上事件重建，不依赖任何后端。
// RPC 对 getLogs 区块范围有限制，因此按区块段分页查询。

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
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
const BLOCK_CHUNK = 9000n; // 常见 RPC 限制在 1 万个区块以内

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

function fmt6(x: bigint): string {
  return fmtToken(x);
}

export default function History() {
  const [account, setAccount] = useState<string>(IS_LOCAL ? ANVIL_ACCOUNTS[0].address : "");
  const [buys, setBuys] = useState<BuyRecord[]>([]);
  const [claims, setClaims] = useState<ClaimRecord[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!isAddress(account)) {
      setBuys([]);
      setClaims([]);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      await loadTokenMeta();
      const latest = await publicClient.getBlockNumber();
      const buyRecords: BuyRecord[] = [];
      const claimRecords: ClaimRecord[] = [];
      // 从合约部署块起分段扫描（FR-W-03：仅靠事件重建历史）
      for (let from = startBlock; from <= latest; from += BLOCK_CHUNK + 1n) {
        const to = from + BLOCK_CHUNK > latest ? latest : from + BLOCK_CHUNK;
        const bought = await publicClient.getLogs({
          address: addresses.lottery,
          event: TICKETS_BOUGHT,
          args: { buyer: account as Address },
          fromBlock: from,
          toBlock: to,
        });
        for (const log of bought) {
          buyRecords.push({
            roundId: Number(log.args.roundId),
            start: Number(log.args.start),
            quantity: Number(log.args.quantity),
            block: log.blockNumber,
          });
        }
        const claimed = await publicClient.getLogs({
          address: addresses.lottery,
          event: PRIZE_CLAIMED,
          args: { winner: account as Address },
          fromBlock: from,
          toBlock: to,
        });
        for (const log of claimed) {
          claimRecords.push({
            roundId: Number(log.args.roundId),
            tier: Number(log.args.tier),
            amount: log.args.amount ?? 0n,
            block: log.blockNumber,
          });
        }
      }
      setBuys(buyRecords.reverse());
      setClaims(claimRecords.reverse());
    } catch (e) {
      setError((e as Error).message.slice(0, 160));
    } finally {
      setLoading(false);
    }
  }, [account]);

  useEffect(() => {
    load();
  }, [load]);

  const totalSpent = buys.reduce((s, b) => s + BigInt(b.quantity) * TOKEN.ticketPrice, 0n);
  const totalWon = claims.reduce((s, c) => s + c.amount, 0n);

  return (
    <main>
      <h1>
        <span>LuckYou</span> 我的记录
      </h1>
      <p className="subtitle">
        <Link href="/" style={{ color: "var(--blue)" }}>
          ← 返回测试台
        </Link>
        {"　"}数据全部来自链上事件（TicketsBought / PrizeClaimed），无后端
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
        {loading && <p style={{ color: "var(--muted)" }}>正在扫描链上事件…</p>}
        {error && <p style={{ color: "var(--red)" }}>加载失败：{error}</p>}
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
