# 部署存档

**为什么需要这份文件**：`broadcast/` 整体不入库（`run-latest.json` 会把构造参数原样
存下，其中含 VRF 订阅 ID，违反 FR-D-04）。但源码验证是**钉在部署时那个 commit 上**的，
构造参数也必须逐字节一致——2026-08-13 验证 `0x95b0…` 时就因为源码树已经领先于链上
而失败，只好建临时 worktree 检出旧 commit 才验通过。

所以这里手工记录**不含任何敏感值**的最小信息集：commit、地址、构造参数。
订阅 ID 一律写占位符，真值只在 `contracts/.env` 里。

> **注意 `anchorTime`**：快节奏实例的锚点是部署那一刻的 `block.timestamp`，
> 事后只能从首期 `closeTime` 反推（`anchor = closeTime − interval`）。
> 差一秒都不会匹配，所以每次部署都要记下来。

---

## Base Sepolia（chainId 84532）

### 当前实例（2026-08-15，冻结候选）

| | |
|---|---|
| **Lottery** | `0x7e88f1Ef79cA08d07f992DB33146eC134130E92B` |
| **LotteryAdmin** | `0x957235d951c9abC5E8e7fBBcA285A5D1Ff52e56f` |
| **CRE 桥接器** | `0x940d69Df2BACa8030322B12660EAd5D0379bfdB0` |
| **commit** | `5a2069a` |
| **anchorTime** | **`1786762780`** |
| 含有 | 原生 ETH、claimTo、Q9 B+C、FR-C-30、第 50 轮 A-1~A-4、**R20 L-1 + R21 C-1** |
| Basescan | 三个合约均已验证 |
| 链上实测 | `buyTickets(uint32,uint32)` 传错期号返回 `RoundMismatch`（选择器 `0xb6188a5a` 精确匹配）；**旧的单参签名已不存在**（调用直接 revert） |

其余构造参数同下表（coordinator / keyHash / ticketPrice / intervals / treasury / feeBps / tierBps / tierWinnerCounts 未变）。

> ⚠️ **每次重部 Lottery 都必须连带重部桥接器**：桥接器把 lottery 地址烧成 immutable，
> 只改 `config.production.json` 的 `receiverAddress` 改不到链上那个值，
> 会得到一个「配置看起来对、链上指向错」的静默失效状态（2026-08-14 实际踩到）。

> ⚠️ **`buyTickets` 签名在 `5a2069a` 变了**（FR-C-09a）。前端/脚本对着旧实例用新 ABI，
> 或对着新实例用旧 ABI，都会直接 revert 而非静默出错——这是刻意的，但换实例时要记得同步 ABI。

### 历史实例（已弃用，勿再使用）

| 地址 | commit | 说明 |
|---|---|---|
| `0x89412E2f96b90f8FFFf52e3f6749b5BbA7cE731c` | `d994d66` | anchor `1786760860`。含 R50 四条修复，不含 L-1/C-1。第 1 期有 100 张票、13:42 开奖，可用 cast 手动触发以采集完整周期数据 |
| `0x95b008Bc0B1969301a6d08828008aA66bC448627` | `d6b9447` | anchor `1786628468`。含 B+C，不含 FR-C-30 |
| `0x66F5a2dc4f14A76D9B29D154D59efA62b1274AaA` | `bb9cb71` | anchor `1786628468`。含 R20 修复，钉死方案尚未移除 |
| `0x229500a0E5102275E7729d84bff0F5b3CAB350F9` | — | 首个原生 ETH 版 |
| `0xd3c091A3B52164f8a9872b14690Bfc486a855548` | — | USDC 版（余额已确认为 0，无资金滞留） |

弃用的实例仍留在 VRF 订阅的 consumer 列表里。它们不会消耗 LINK（不再有人触发开奖），
清理与否不影响当前实例。

---

## 验证命令模板

```bash
# anchorTime 从本文件查，或用 closeTime − interval 反推
ARGS=$(cast abi-encode "constructor(address,uint256,bytes32,uint256,uint64,uint32[],address,uint16,uint16[],uint8[])" \
  <coordinator> $VRF_SUBSCRIPTION_ID <keyHash> 100000000000000 <anchor> "[7200]" <treasury> 100 "[6000,2500,1500]" "[1,2,5]")

forge verify-contract <address> src/Lottery.sol:Lottery --chain-id 84532 \
  --constructor-args "$ARGS" --verifier etherscan --etherscan-api-key $BASESCAN_API_KEY --watch
```

**若源码树已领先于链上**（部署后又改过合约），必须先检出部署时的 commit：

```bash
git worktree add /tmp/verify <commit>
# worktree 里没有 lib/（submodule），软链到主仓库的即可
```

Sourcify 是另一条不需要 API key 的路（`--verifier sourcify`），且比对完整编译元数据、
技术上更强；但普通用户默认去 Basescan，两边都做为宜。
