"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { Address } from "viem";
import {
  ANVIL_ACCOUNTS,
  IS_LOCAL,
  addresses,
  advanceTime,
  chain,
  connectInjected,
  erc20Abi,
  selectedWalletName,
  expectedChainId,
  injectedWalletFor,
  lotteryAbi,
  publicClient,
  vrfAbi,
  walletFor,
} from "@/lib/contracts";

const STATE_NAMES = ["未创建", "售票中", "开奖中", "已结算", "已作废"] as const;
const STATE_TAGS = ["", "open", "drawing", "settled", "voided"] as const;
const TIER_NAMES = ["一等奖", "二等奖", "三等奖"];
const HISTORY_LIMIT = 8;

interface RoundInfo {
  id: number;
  state: number;
  closeTime: bigint;
  drawTime: bigint;
  ticketCount: number;
  pot: bigint;
  tier1Carry: bigint;
  randomSeed: bigint;
  vrfRequestId: bigint;
  myTickets: bigint;
  myPending: bigint[];
}

interface LogEntry {
  time: string;
  kind: "ok" | "err" | "info";
  text: string;
}

function fmt6(x: bigint): string {
  return `${(Number(x) / 1e6).toLocaleString("zh-CN", { maximumFractionDigits: 6 })} USDC`;
}

function fmtTs(t: bigint): string {
  if (t === 0n) return "-";
  return new Date(Number(t) * 1000).toLocaleString("zh-CN", { hour12: false });
}

function countdown(target: bigint, now: bigint): string {
  if (now >= target) return "已到";
  const d = Number(target - now);
  const h = Math.floor(d / 3600);
  const m = Math.floor((d % 3600) / 60);
  const s = d % 60;
  return `${h}小时${m}分${s}秒`;
}

function short(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export default function Home() {
  const [account, setAccount] = useState<Address | null>(IS_LOCAL ? ANVIL_ACCOUNTS[0].address : null);
  const [chainNow, setChainNow] = useState<bigint>(0n);
  const [currentId, setCurrentId] = useState(0);
  const [rounds, setRounds] = useState<RoundInfo[]>([]);
  const [myRanges, setMyRanges] = useState<{ start: number; end: number }[]>([]);
  const [balance, setBalance] = useState<bigint>(0n);
  const [allowance, setAllowance] = useState<bigint>(0n);
  const [fees, setFees] = useState<bigint>(0n);
  const [treasuryBal, setTreasuryBal] = useState<bigint>(0n);
  const [paused, setPaused] = useState(false);
  const [tierWinners, setTierWinners] = useState<number[]>([1, 2, 5]);
  const [winners, setWinners] = useState<Map<number, { tickets: number[]; owners: Address[] }>>(new Map());
  const [qty, setQty] = useState("10");
  const [injectAmt, setInjectAmt] = useState("100");
  const [busy, setBusy] = useState<string | null>(null);
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [wrongChain, setWrongChain] = useState(false);

  const log = useCallback((kind: LogEntry["kind"], text: string) => {
    const time = new Date().toLocaleTimeString("zh-CN", { hour12: false });
    setLogs((prev) => [{ time, kind, text }, ...prev].slice(0, 30));
  }, []);

  const refresh = useCallback(async () => {
    try {
      // FR-W-05 精神：写操作前校验链 ID，这里在轮询时持续校验
      const chainId = await publicClient.getChainId();
      setWrongChain(chainId !== chain.id);

      const block = await publicClient.getBlock();
      setChainNow(block.timestamp);

      const cur = (await publicClient.readContract({
        address: addresses.lottery,
        abi: lotteryAbi,
        functionName: "s_currentRound",
      })) as number;
      setCurrentId(cur);

      const from = Math.max(1, cur - HISTORY_LIMIT + 1);
      const infos: RoundInfo[] = [];
      for (let id = cur; id >= from; id--) {
        const r = (await publicClient.readContract({
          address: addresses.lottery,
          abi: lotteryAbi,
          functionName: "getRound",
          args: [id],
        })) as readonly [number, bigint, bigint, number, bigint, bigint, bigint, number, boolean];
        const [req] = (await publicClient.readContract({
          address: addresses.lottery,
          abi: lotteryAbi,
          functionName: "vrfRequestOf",
          args: [id],
        })) as readonly [bigint, bigint];
        const myTickets = account
          ? ((await publicClient.readContract({
              address: addresses.lottery,
              abi: lotteryAbi,
              functionName: "ticketsOwned",
              args: [id, account],
            })) as bigint)
          : 0n;
        const myPending =
          r[0] === 3 && account
            ? ([
                ...((await publicClient.readContract({
                  address: addresses.lottery,
                  abi: lotteryAbi,
                  functionName: "pendingPrizes",
                  args: [id, account],
                })) as readonly bigint[]),
              ] as bigint[])
            : [];
        infos.push({
          id,
          state: r[0],
          closeTime: r[1],
          drawTime: r[2],
          ticketCount: r[3],
          pot: r[4],
          tier1Carry: r[5],
          randomSeed: r[6],
          vrfRequestId: req,
          myTickets,
          myPending,
        });
      }
      setRounds(infos);

      if (account) {
        const curRanges = (await publicClient.readContract({
          address: addresses.lottery,
          abi: lotteryAbi,
          functionName: "getRanges",
          args: [cur],
        })) as readonly { start: number; end: number; owner: Address }[];
        setMyRanges(
          curRanges
            .filter((r) => r.owner.toLowerCase() === account.toLowerCase())
            .map((r) => ({ start: r.start, end: r.end })),
        );
      } else {
        setMyRanges([]);
      }

      const settled = infos.filter((r) => r.state === 3);
      const winnersMap = new Map<number, { tickets: number[]; owners: Address[] }>();
      for (const r of settled) {
        const [tickets, owners] = (await publicClient.readContract({
          address: addresses.lottery,
          abi: lotteryAbi,
          functionName: "winnersOf",
          args: [r.id],
        })) as readonly [readonly number[], readonly Address[]];
        winnersMap.set(r.id, { tickets: [...tickets], owners: [...owners] });
      }
      setWinners(winnersMap);

      setBalance(
        account
          ? ((await publicClient.readContract({
              address: addresses.usdc,
              abi: erc20Abi,
              functionName: "balanceOf",
              args: [account],
            })) as bigint)
          : 0n,
      );
      setAllowance(
        account
          ? ((await publicClient.readContract({
              address: addresses.usdc,
              abi: erc20Abi,
              functionName: "allowance",
              args: [account, addresses.lottery],
            })) as bigint)
          : 0n,
      );
      setFees(
        (await publicClient.readContract({
          address: addresses.lottery,
          abi: lotteryAbi,
          functionName: "s_accruedFees",
        })) as bigint,
      );
      setTreasuryBal(
        (await publicClient.readContract({
          address: addresses.usdc,
          abi: erc20Abi,
          functionName: "balanceOf",
          args: [addresses.treasury],
        })) as bigint,
      );
      setPaused(
        (await publicClient.readContract({
          address: addresses.lottery,
          abi: lotteryAbi,
          functionName: "s_salesPaused",
        })) as boolean,
      );
      const [, counts] = (await publicClient.readContract({
        address: addresses.lottery,
        abi: lotteryAbi,
        functionName: "getTierConfig",
      })) as readonly [readonly number[], readonly number[]];
      setTierWinners([...counts]);
    } catch (e) {
      log("err", `刷新失败：${(e as Error).message.slice(0, 120)}`);
    }
  }, [account, log]);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 3000);
    return () => clearInterval(t);
  }, [refresh]);

  const act = useCallback(
    async (label: string, fn: () => Promise<void>) => {
      setBusy(label);
      log("info", `${label}…`);
      try {
        await fn();
        log("ok", `${label} 成功`);
      } catch (e) {
        const msg = (e as { shortMessage?: string; message: string }).shortMessage ?? (e as Error).message;
        log("err", `${label} 失败：${msg.slice(0, 160)}`);
      } finally {
        setBusy(null);
        await refresh();
      }
    },
    [log, refresh],
  );

  const write = useCallback(
    async (address: Address, abi: typeof lotteryAbi, functionName: string, args: unknown[]) => {
      if (!account) throw new Error("请先连接钱包");
      const client = IS_LOCAL ? walletFor(account) : injectedWalletFor(account);
      const hash = await client.writeContract({
        address,
        abi,
        functionName,
        args,
        chain,
        account,
      });
      await publicClient.waitForTransactionReceipt({ hash });
    },
    [account],
  );

  const current = rounds.find((r) => r.id === currentId);
  const drawingRounds = rounds.filter((r) => r.state === 2);
  const cost = useMemo(() => {
    const n = parseInt(qty, 10);
    return Number.isFinite(n) && n > 0 ? BigInt(n) * 1_000_000n : 0n;
  }, [qty]);
  const needApprove = cost > 0n && allowance < cost;

  const totalPending = rounds.reduce(
    (sum, r) => sum + r.myPending.reduce((s, x) => s + x, 0n),
    0n,
  );

  const slotTier = useCallback(
    (slot: number): number => {
      let acc = 0;
      for (let t = 0; t < tierWinners.length; t++) {
        acc += tierWinners[t];
        if (slot < acc) return t;
      }
      return tierWinners.length - 1;
    },
    [tierWinners],
  );

  return (
    <main>
      <h1>
        <span>LuckYou</span> 本地测试台
      </h1>
      <p className="subtitle">
        {chain.name} (chainId {expectedChainId}) · Lottery <span className="addr">{addresses.lottery}</span> · 票价 1
        USDC · 抽成 1% ·{" "}
        <a href="/history" style={{ color: "var(--blue)" }}>
          我的记录 →
        </a>
      </p>

      {wrongChain && <div className="banner" style={{ borderColor: "var(--red)" }}>⚠ RPC 链 ID 不是 31337，请确认 anvil 已启动</div>}

      {totalPending > 0n && (
        <div className="banner">🎉 你有 {fmt6(totalPending)} 奖金未领取！在下方「我的奖金」中一键领取。</div>
      )}

      <div className="grid">
        <section className="card">
          <h2>当前期 #{currentId}</h2>
          {current ? (
            <>
              <div className="row">
                <span className="k">状态</span>
                <span className={`tag ${STATE_TAGS[current.state]}`}>
                  {STATE_NAMES[current.state]}
                  {current.state === 1 && chainNow >= current.closeTime ? "（已封盘）" : ""}
                </span>
              </div>
              <div className="row">
                <span className="k">奖池</span>
                <span className="v big">{fmt6(current.pot)}</span>
              </div>
              {current.tier1Carry > 0n && (
                <div className="row">
                  <span className="k">滚入一等奖</span>
                  <span className="v">+{fmt6(current.tier1Carry)}</span>
                </div>
              )}
              <div className="row">
                <span className="k">已售票数</span>
                <span className="v">{current.ticketCount}</span>
              </div>
              <div className="row">
                <span className="k">停售时间</span>
                <span className="v">{fmtTs(current.closeTime)}</span>
              </div>
              <div className="row">
                <span className="k">开奖时间</span>
                <span className="v">{fmtTs(current.drawTime)}</span>
              </div>
              <div className="row">
                <span className="k">距停售</span>
                <span className="v">{countdown(current.closeTime, chainNow)}</span>
              </div>
              <div className="row">
                <span className="k">距开奖</span>
                <span className="v">{countdown(current.drawTime, chainNow)}</span>
              </div>
              <div className="row">
                <span className="k">我的持票</span>
                <span className="v">{current.myTickets.toString()} 张</span>
              </div>
              {myRanges.length > 0 && (
                <div className="row">
                  <span className="k">我的票号</span>
                  <span className="v">
                    {myRanges
                      .map((r) => (r.end - r.start === 1 ? `#${r.start}` : `#${r.start}~${r.end - 1}`))
                      .join("，")}
                  </span>
                </div>
              )}
            </>
          ) : (
            <p>加载中…</p>
          )}
        </section>

        <section className="card">
          <h2>
            购票
            {account
              ? `（${IS_LOCAL ? ANVIL_ACCOUNTS.find((a) => a.address === account)?.name : short(account)}）`
              : ""}
          </h2>
          {IS_LOCAL ? (
            <div className="row">
              <span className="k">切换账户</span>
              <select value={account ?? ""} onChange={(e) => setAccount(e.target.value as Address)}>
                {ANVIL_ACCOUNTS.map((a) => (
                  <option key={a.address} value={a.address}>
                    {a.name} {short(a.address)}
                  </option>
                ))}
              </select>
            </div>
          ) : (
            <div className="row">
              <span className="k">钱包</span>
              <span className="v">
                {account ? (
                  <span className="addr">{account}</span>
                ) : (
                  <button
                    className="btn primary"
                    disabled={busy !== null}
                    onClick={() =>
                      act("连接钱包", async () => {
                        const a = await connectInjected();
                        setAccount(a);
                        log("info", `已选用钱包：${selectedWalletName}，地址 ${short(a)}`);
                      })
                    }
                  >
                    🔗 连接 MetaMask
                  </button>
                )}
              </span>
            </div>
          )}
          <div className="row">
            <span className="k">USDC 余额</span>
            <span className="v">{fmt6(balance)}</span>
          </div>
          <div className="row">
            <span className="k">已授权额度</span>
            <span className="v">{fmt6(allowance)}</span>
          </div>
          <div style={{ marginTop: 8 }}>
            <input value={qty} onChange={(e) => setQty(e.target.value)} placeholder="张数" />
            {/* FR-W-02：approve 与 buy 两步独立状态 */}
            <button
              className="btn"
              disabled={busy !== null || !needApprove}
              onClick={() => act(`授权 ${fmt6(cost)}`, () => write(addresses.usdc, erc20Abi, "approve", [addresses.lottery, cost]))}
            >
              {busy?.startsWith("授权") ? "授权中…" : "1️⃣ 授权"}
            </button>
            <button
              className="btn primary"
              disabled={busy !== null || cost === 0n || needApprove}
              onClick={() => act(`购买 ${qty} 张`, () => write(addresses.lottery, lotteryAbi, "buyTickets", [parseInt(qty, 10)]))}
            >
              {busy?.startsWith("购买") ? "购票中…" : `2️⃣ 购票（${fmt6(cost)}）`}
            </button>
          </div>
          <div style={{ marginTop: 8 }}>
            {IS_LOCAL && (
              <button
                className="btn"
                disabled={busy !== null}
                onClick={() =>
                  act("领取 10000 测试 USDC", () => write(addresses.usdc, erc20Abi, "mint", [account, 10_000_000_000n]))
                }
              >
                💧 领测试币
              </button>
            )}
            <input value={injectAmt} onChange={(e) => setInjectAmt(e.target.value)} placeholder="注资额" />
            <button
              className="btn"
              disabled={busy !== null}
              onClick={() =>
                act(`注资 ${injectAmt} USDC`, async () => {
                  const amt = BigInt(Math.round(parseFloat(injectAmt) * 1e6));
                  if (allowance < amt) {
                    await write(addresses.usdc, erc20Abi, "approve", [addresses.lottery, amt]);
                  }
                  await write(addresses.lottery, lotteryAbi, "injectPot", [currentId, amt]);
                })
              }
            >
              💰 注资奖池
            </button>
          </div>
        </section>

        <section className="card">
          <h2>{IS_LOCAL ? "时间与开奖控制（anvil 专用）" : "开奖控制"}</h2>
          <div className="row">
            <span className="k">链上时间</span>
            <span className="v">{fmtTs(chainNow)}</span>
          </div>
          {IS_LOCAL && (
            <div style={{ marginTop: 8 }}>
              <button
                className="btn"
                disabled={busy !== null || !current || chainNow >= current.closeTime}
                onClick={() => act("快进到停售（封盘）", () => advanceTime(Number(current!.closeTime - chainNow) + 1))}
              >
                ⏩ 快进到停售
              </button>
              <button
                className="btn"
                disabled={busy !== null || !current || chainNow >= current.drawTime}
                onClick={() => act("快进到开奖时刻", () => advanceTime(Number(current!.drawTime - chainNow) + 1))}
              >
                ⏩ 快进到开奖
              </button>
              <button className="btn" disabled={busy !== null} onClick={() => act("快进 1 天", () => advanceTime(86400))}>
                +1 天
              </button>
              <button
                className="btn"
                disabled={busy !== null}
                onClick={() => act("快进 91 天（过领奖期）", () => advanceTime(91 * 86400))}
              >
                +91 天
              </button>
            </div>
          )}
          <div style={{ marginTop: 8 }}>
            <button
              className="btn warn"
              disabled={busy !== null || !current || current.state !== 1 || chainNow < current.drawTime}
              onClick={() => act("触发开奖 performUpkeep", () => write(addresses.lottery, lotteryAbi, "performUpkeep", ["0x"]))}
            >
              🎰 触发开奖{IS_LOCAL ? "（模拟 keeper）" : "（keeper 兜底）"}
            </button>
            {IS_LOCAL &&
              drawingRounds.map((r) => (
                <button
                  key={r.id}
                  className="btn warn"
                  disabled={busy !== null}
                  onClick={() =>
                    act(`模拟 VRF 回调（第 ${r.id} 期）`, () =>
                      write(addresses.vrfCoordinator, vrfAbi, "fulfillRandomWords", [r.vrfRequestId, addresses.lottery]),
                    )
                  }
                >
                  🎲 VRF 回调开出第 {r.id} 期
                </button>
              ))}
            {!IS_LOCAL &&
              drawingRounds.map((r) => (
                <button
                  key={r.id}
                  className="btn warn"
                  disabled={busy !== null}
                  onClick={() => act(`重试第 ${r.id} 期 VRF`, () => write(addresses.lottery, lotteryAbi, "retryDraw", [r.id]))}
                >
                  🔁 重试第 {r.id} 期 VRF（超时 3 小时后可用）
                </button>
              ))}
          </div>
          <p style={{ color: "var(--muted)", marginTop: 8, fontSize: 12 }}>
            {IS_LOCAL
              ? "本地没有 Chainlink 节点：keeper 与 VRF 回调都用按钮手动模拟。测试网/主网由 Automation 与 VRF 自动完成。"
              : "测试网由 Chainlink Automation 自动开奖、VRF 自动回调；上面的按钮仅作 keeper 未执行时的手动兜底。"}
          </p>
        </section>

        <section className="card">
          <h2>我的奖金</h2>
          {rounds.filter((r) => r.state === 3 && r.myPending.some((x) => x > 0n)).length === 0 ? (
            <p style={{ color: "var(--muted)" }}>暂无可领取奖金。购票并开奖后，中奖会显示在这里。</p>
          ) : (
            rounds
              .filter((r) => r.state === 3 && r.myPending.some((x) => x > 0n))
              .map((r) => (
                <div key={r.id} style={{ marginBottom: 8 }}>
                  <strong>第 {r.id} 期</strong>
                  {r.myPending.map((amt, tier) =>
                    amt > 0n ? (
                      <div className="row" key={tier}>
                        <span className="k">{TIER_NAMES[tier]}</span>
                        <span className="v">
                          {fmt6(amt)}{" "}
                          <button
                            className="btn primary"
                            disabled={busy !== null}
                            onClick={() => act(`领取第 ${r.id} 期${TIER_NAMES[tier]}`, () => write(addresses.lottery, lotteryAbi, "claim", [r.id, tier]))}
                          >
                            领奖
                          </button>
                        </span>
                      </div>
                    ) : null,
                  )}
                </div>
              ))
          )}
        </section>

        <section className="card">
          <h2>运营（owner = {IS_LOCAL ? "账户 #0" : "部署者"}）</h2>
          <div className="row">
            <span className="k">累计抽成</span>
            <span className="v">{fmt6(fees)}</span>
          </div>
          <div className="row">
            <span className="k">treasury 余额</span>
            <span className="v">{fmt6(treasuryBal)}</span>
          </div>
          <div className="row">
            <span className="k">售票状态</span>
            <span className="v">{paused ? "⏸ 已暂停" : "▶ 正常"}</span>
          </div>
          <div style={{ marginTop: 8 }}>
            <button
              className="btn"
              disabled={busy !== null || fees === 0n}
              onClick={() => act("提取抽成到 treasury", () => write(addresses.lottery, lotteryAbi, "withdrawFees", []))}
            >
              提取抽成
            </button>
            <button
              className="btn"
              disabled={busy !== null}
              onClick={() => act(paused ? "恢复售票" : "暂停售票", () => write(addresses.lottery, lotteryAbi, "setSalesPaused", [!paused]))}
            >
              {paused ? "恢复售票" : "暂停售票"}
            </button>
          </div>
          <p style={{ color: "var(--muted)", marginTop: 8, fontSize: 12 }}>
            {IS_LOCAL ? "owner 操作需切到账户 #0。" : "owner 操作需用部署者钱包。"}
            暂停只影响购票，领奖不受影响（FR-C-23）。
          </p>
        </section>

        <section className="card">
          <h2>操作日志</h2>
          <div className="log">
            {logs.length === 0 && <div className="info">暂无操作</div>}
            {logs.map((l, i) => (
              <div key={i} className={l.kind}>
                [{l.time}] {l.text}
              </div>
            ))}
          </div>
        </section>

        <section className="card full">
          <h2>期次历史</h2>
          <table>
            <thead>
              <tr>
                <th>期号</th>
                <th>状态</th>
                <th>票数</th>
                <th>奖池</th>
                <th>滚入一等奖</th>
                <th>停售时间</th>
                <th>我的持票</th>
              </tr>
            </thead>
            <tbody>
              {rounds.map((r) => (
                <tr key={r.id}>
                  <td>#{r.id}</td>
                  <td>
                    <span className={`tag ${STATE_TAGS[r.state]}`}>{STATE_NAMES[r.state]}</span>
                  </td>
                  <td>{r.ticketCount}</td>
                  <td>{fmt6(r.pot)}</td>
                  <td>{r.tier1Carry > 0n ? fmt6(r.tier1Carry) : "-"}</td>
                  <td>{fmtTs(r.closeTime)}</td>
                  <td>{r.myTickets.toString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>

        {[...winners.entries()].map(([id, w]) => (
          <section className="card full" key={id}>
            <h2>第 {id} 期开奖结果</h2>
            <table>
              <thead>
                <tr>
                  <th>奖级</th>
                  <th>中奖票号</th>
                  <th>中奖地址</th>
                </tr>
              </thead>
              <tbody>
                {w.tickets.map((t, i) => (
                  <tr key={i}>
                    <td>{TIER_NAMES[slotTier(i)]}</td>
                    <td>#{t}</td>
                    <td className="addr">
                      {w.owners[i]}
                      {ANVIL_ACCOUNTS.some((a) => a.address.toLowerCase() === w.owners[i].toLowerCase())
                        ? `（${ANVIL_ACCOUNTS.find((a) => a.address.toLowerCase() === w.owners[i].toLowerCase())?.name}）`
                        : ""}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>
        ))}
      </div>
    </main>
  );
}
