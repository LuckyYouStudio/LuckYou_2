"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Address } from "viem";
import {
  ANVIL_ACCOUNTS,
  IS_LOCAL,
  addresses,
  advanceTime,
  chain,
  connectInjected,
  switchToTargetChain,
  walletChainId,
  fmtToken,
  loadTokenMeta,
  parseTokenAmount,
  selectedWalletName,
  TOKEN,
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
const HISTORY_LIMIT = 8; // 期次历史表的显示条数
// 领奖窗口 90 天；按最短场次间隔（快节奏实例 2 小时）反推需回溯的期数上限，
// 避免中奖者因界面只看最近几期而错失奖金（审计第九轮 C1）
const CLAIM_SCAN_ROUNDS = 120;

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

// 金额格式化统一走 lib/contracts 的链上元数据（审计 E）
const fmt6 = fmtToken;

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
  const [fees, setFees] = useState<bigint>(0n);
  const [treasuryBal, setTreasuryBal] = useState<bigint>(0n);
  const [paused, setPaused] = useState(false);
  const [ticketPrice, setTicketPrice] = useState<bigint>(0n);
  // 领奖窗口 90 天远长于显示的 8 期，独立低频扫描，避免中奖者错失奖金（审计第九轮 C1）
  const [claimable, setClaimable] = useState<{ roundId: number; tier: number; amount: bigint; deadline: bigint }[]>([]);
  // 结算时按配比释放，原始 pot 与实际可分配额在大额滚存 + 低参与度时可差数量级
  const [distributable, setDistributable] = useState<bigint>(0n);
  const [salesOpen, setSalesOpen] = useState(true);
  const [feeBps, setFeeBps] = useState<number>(0);
  const [treasuryAddr, setTreasuryAddr] = useState<Address | null>(null);
  const [winners, setWinners] = useState<Map<number, { tickets: number[]; owners: Address[]; tiers: number[] }>>(
    new Map(),
  );
  const winnersCache = useRef(new Map<number, { tickets: number[]; owners: Address[]; tiers: number[] }>());
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
        // 只有 DRAWING 状态才需要 requestId（本地模拟回调/测试网重试用）
        const [req] =
          r[0] === 2
            ? ((await publicClient.readContract({
                address: addresses.lottery,
                abi: lotteryAbi,
                functionName: "vrfRequestOf",
                args: [id],
              })) as readonly [bigint, bigint])
            : ([0n, 0n] as const);
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
          args: [cur, 0, 200], // 分页：一次性拉全部在 range 数多时会超出节点 eth_call 上限
        })) as readonly { start: number; end: number; owner: Address }[];
        setMyRanges(
          curRanges
            .filter((r) => r.owner.toLowerCase() === account.toLowerCase())
            .map((r) => ({ start: r.start, end: r.end })),
        );
      } else {
        setMyRanges([]);
      }

      // 已结算期的开奖结果不可变，只拉一次并缓存，减轻公共 RPC 压力
      const settled = infos.filter((r) => r.state === 3);
      for (const r of settled) {
        if (winnersCache.current.has(r.id)) continue;
        // 合约直接返回每个中奖者所属奖级（审计 D），前端不再靠 slot 顺序推断
        const [tickets, owners, tiers] = (await publicClient.readContract({
          address: addresses.lottery,
          abi: lotteryAbi,
          functionName: "winnersOf",
          args: [r.id],
        })) as readonly [readonly number[], readonly Address[], readonly number[]];
        winnersCache.current.set(r.id, { tickets: [...tickets], owners: [...owners], tiers: [...tiers] });
      }
      setWinners(new Map([...winnersCache.current].filter(([id]) => settled.some((r) => r.id === id))));

      setBalance(account ? await publicClient.getBalance({ address: account }) : 0n);
      setFees(
        (await publicClient.readContract({
          address: addresses.lottery,
          abi: lotteryAbi,
          functionName: "s_accruedFees",
        })) as bigint,
      );
      const liveTreasury = (await publicClient.readContract({
        address: addresses.lottery,
        abi: lotteryAbi,
        functionName: "s_treasury",
      })) as Address;
      setTreasuryAddr(liveTreasury);
      setFeeBps(
        (await publicClient.readContract({
          address: addresses.lottery,
          abi: lotteryAbi,
          functionName: "s_feeBps",
        })) as number,
      );
      setTreasuryBal(await publicClient.getBalance({ address: liveTreasury }));
      setPaused(
        (await publicClient.readContract({
          address: addresses.lottery,
          abi: lotteryAbi,
          functionName: "s_salesPaused",
        })) as boolean,
      );
      setDistributable(
        (await publicClient.readContract({
          address: addresses.lottery,
          abi: lotteryAbi,
          functionName: "distributableEstimate",
          args: [cur],
        })) as bigint,
      );
      setSalesOpen(
        (await publicClient.readContract({
          address: addresses.lottery,
          abi: lotteryAbi,
          functionName: "salesOpenFor",
          args: [cur],
        })) as boolean,
      );
      // 票价是 immutable，共享模块只读一次（审计 E）
      await loadTokenMeta();
      if (ticketPrice !== TOKEN.ticketPrice) setTicketPrice(TOKEN.ticketPrice);
    } catch (e) {
      log("err", `刷新失败：${(e as Error).message.slice(0, 120)}`);
    }
  }, [account, log]);

  // 低频扫描整个领奖窗口，独立于显示用的 8 期轮询（审计第九轮 C1）
  const scanClaimable = useCallback(async () => {
    if (!account || currentId === 0) {
      setClaimable([]);
      return;
    }
    try {
      const from = Math.max(1, currentId - CLAIM_SCAN_ROUNDS + 1);
      const ids: number[] = [];
      for (let id = currentId; id >= from; id--) ids.push(id);
      const results = await Promise.all(
        ids.map(async (id) => {
          const amounts = (await publicClient.readContract({
            address: addresses.lottery,
            abi: lotteryAbi,
            functionName: "pendingPrizes",
            args: [id, account],
          })) as readonly bigint[];
          if (!amounts.some((a) => a > 0n)) return [];
          const [, deadline] = (await publicClient.readContract({
            address: addresses.lottery,
            abi: lotteryAbi,
            functionName: "claimDeadlineOf",
            args: [id],
          })) as readonly [bigint, bigint];
          return amounts
            .map((amount, tier) => ({ roundId: id, tier, amount, deadline }))
            .filter((x) => x.amount > 0n);
        }),
      );
      setClaimable(results.flat());
    } catch {
      // 扫描失败不影响主界面，下一轮重试
    }
  }, [account, currentId]);

  useEffect(() => {
    scanClaimable();
    const t = setInterval(scanClaimable, 60000);
    return () => clearInterval(t);
  }, [scanClaimable]);

  useEffect(() => {
    refresh();
    // 本地链无限流可以快轮询；公共测试网 RPC 放缓到 10 秒
    const t = setInterval(refresh, IS_LOCAL ? 3000 : 10000);
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
    async (
      address: Address,
      abi: typeof lotteryAbi,
      functionName: string,
      args: unknown[],
      value?: bigint,
    ) => {
      if (!account) throw new Error("请先连接钱包");
      // FR-W-05：写操作前校验**钱包**所在链（原实现查的是自家 RPC，恒等于目标链，
      // 永远发现不了用户钱包在别的网络上）——审计第九轮 H3
      const wcid = await walletChainId();
      if (wcid !== expectedChainId) {
        setWrongChain(true);
        throw new Error(`钱包当前在链 ${wcid}，请切换到 ${chain.name}（${expectedChainId}）`);
      }
      setWrongChain(false);
      const client = IS_LOCAL ? walletFor(account) : injectedWalletFor(account);
      const hash = await client.writeContract({
        address,
        abi,
        functionName,
        args,
        chain,
        account,
        value,
      });
      // viem 在交易 revert 时也正常 resolve，必须自己查 status，
      // 否则失败的领奖/购票会被报成「成功」，用户以为拿到了钱（审计第九轮 H1）
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") {
        throw new Error("交易已上链但执行失败（reverted），资金未变动");
      }
    },
    [account],
  );

  const current = rounds.find((r) => r.id === currentId);
  const drawingRounds = rounds.filter((r) => r.state === 2);
  // 严格整数解析并遵守合约的 MAX_TICKETS_PER_TX，避免用户白付 gas
  // 才在 buyTickets 撞 ExceedsMaxPerTx（审计第九轮 L1/L2）
  const qtyValid = /^\d+$/.test(qty.trim()) && Number(qty) >= 1 && Number(qty) <= 1000;
  const cost = useMemo(() => {
    if (!/^\d+$/.test(qty.trim())) return 0n;
    const n = Number(qty);
    return n >= 1 && n <= 1000 ? BigInt(n) * ticketPrice : 0n;
  }, [qty, ticketPrice]);
  // 原生币计价下票款与 gas 出自同一余额：余额恰好等于票款也发不出交易
  const notEnough = cost > 0n && account !== null && balance <= cost;

  const totalPending = claimable.reduce((sum, c) => sum + c.amount, 0n);

  return (
    <main>
      <h1>
        <span>LuckYou</span> {IS_LOCAL ? "本地测试台" : "Base Sepolia 测试站"}
      </h1>
      <p className="subtitle">
        {chain.name} (chainId {expectedChainId}) · Lottery <span className="addr">{addresses.lottery}</span> · 票价{" "}
        {ticketPrice > 0n ? fmt6(ticketPrice) : "…"} · 抽成 {(feeBps / 100).toFixed(2)}% ·{" "}
        <a href="/history" style={{ color: "var(--blue)" }}>
          我的记录 →
        </a>
      </p>

      {wrongChain && (
        <div className="banner" style={{ borderColor: "var(--red)" }}>
          {`⚠ 钱包不在 ${chain.name}（链 ID ${expectedChainId}），交易将无法发出。`}{" "}
          {!IS_LOCAL && (
            <button
              className="btn primary"
              onClick={() => act("切换网络", async () => {
                await switchToTargetChain();
                setWrongChain(false);
              })}
            >
              切换网络
            </button>
          )}
        </div>
      )}

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
                  {current.state === 1 && chainNow >= current.drawTime
                    ? "开奖中"
                    : STATE_NAMES[current.state]}
                  {current.state === 1 && chainNow >= current.closeTime && chainNow < current.drawTime
                    ? "（已封盘）"
                    : ""}
                  {current.state === 1 && chainNow >= current.drawTime ? "（等待 keeper 触发）" : ""}
                </span>
              </div>
              <div className="row">
                <span className="k">奖池</span>
                <span className="v big">{fmt6(current.pot)}</span>
              </div>
              {distributable < current.pot && (
                <div className="row">
                  <span className="k">本期实际可分配</span>
                  <span className="v" title="滚存/注资按本期售票额配比释放，超出部分顺延到后续期">
                    {fmt6(distributable)}
                  </span>
                </div>
              )}
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
            <span className="k">{TOKEN.symbol} 余额</span>
            <span className="v">{fmt6(balance)}</span>
          </div>
          <div style={{ marginTop: 8 }}>
            <input value={qty} onChange={(e) => setQty(e.target.value)} placeholder="张数" />
            {!qtyValid && qty.trim() !== "" && (
              <span style={{ color: "var(--red)", fontSize: 12 }}>张数需为 1~1000 的整数</span>
            )}
            {/* 原生币计价：一步成交，不再需要 approve（FR-C-01） */}
            <button
              className="btn primary"
              disabled={
                busy !== null ||
                cost === 0n ||
                notEnough ||
                !current ||
                current.state !== 1 ||
                !salesOpen ||
                chainNow >= current.closeTime
              }
              onClick={() =>
                act(`购买 ${qty} 张`, () =>
                  write(addresses.lottery, lotteryAbi, "buyTickets", [parseInt(qty, 10)], cost),
                )
              }
            >
              {busy?.startsWith("购买") ? "购票中…" : `🎟️ 购票（${fmt6(cost)}）`}
            </button>
            {notEnough && (
              <span style={{ color: "var(--red)", fontSize: 12 }}>
                余额不足（还需留一点付 gas）
              </span>
            )}
          </div>
          <div style={{ marginTop: 8 }}>
            <input value={injectAmt} onChange={(e) => setInjectAmt(e.target.value)} placeholder="注资额" />
            <button
              className="btn"
              disabled={
                busy !== null || !current || current.state !== 1 || chainNow >= current.closeTime
              }
              onClick={() =>
                act(`注资 ${injectAmt} ${TOKEN.symbol}`, async () => {
                  // 用整数解析，避免 18 位精度下 JS Number 超出安全整数范围而失真（审计 Low）
                  const amt = parseTokenAmount(injectAmt);
                  if (amt === 0n) throw new Error("注资金额无效");
                  await write(addresses.lottery, lotteryAbi, "injectPot", [currentId], amt);
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
              : "测试网开奖由 keeper 自动触发（CRE 工作流迁移中）、Chainlink VRF 自动回调；上面的按钮仅作 keeper 未执行时的手动兜底，任何人可点。"}
          </p>
        </section>

        <section className="card">
          <h2>我的奖金</h2>
          {claimable.length === 0 ? (
            <p style={{ color: "var(--muted)" }}>暂无可领取奖金。购票并开奖后，中奖会显示在这里。</p>
          ) : (
            claimable.map((c) => (
              <div className="row" key={`${c.roundId}-${c.tier}`}>
                <span className="k">
                  第 {c.roundId} 期 · {TIER_NAMES[c.tier] ?? `T${c.tier}`}
                  <br />
                  <span style={{ fontSize: 12, color: "var(--muted)" }}>
                    领奖截止 {fmtTs(c.deadline)}
                  </span>
                </span>
                <span className="v">
                  {fmt6(c.amount)}{" "}
                  <button
                    className="btn primary"
                    disabled={busy !== null}
                    onClick={() =>
                      act(`领取第 ${c.roundId} 期${TIER_NAMES[c.tier] ?? ""}`, async () => {
                        await write(addresses.lottery, lotteryAbi, "claim", [c.roundId, c.tier]);
                        await scanClaimable();
                      })
                    }
                  >
                    领奖
                  </button>
                </span>
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
            <span className="k">treasury</span>
            <span className="v addr">{treasuryAddr ? short(treasuryAddr) : "…"}</span>
          </div>
          <div className="row">
            <span className="k">treasury 余额</span>
            <span className="v">{fmt6(treasuryBal)}</span>
          </div>
          <div className="row">
            <span className="k">售票状态</span>
            <span className="v">
              {salesOpen ? "▶ 本期可购票" : "⏸ 本期已禁售"}
              {paused !== !salesOpen ? `（全局开关：${paused ? "暂停" : "正常"}，下期起生效）` : ""}
            </span>
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
                    <td>{TIER_NAMES[w.tiers[i]] ?? `T${w.tiers[i]}`}</td>
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
