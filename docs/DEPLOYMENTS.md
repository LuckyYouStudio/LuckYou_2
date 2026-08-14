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

### 当前实例

| | |
|---|---|
| **Lottery** | `0x23bec642861319f5eDc6716A881164Aee3585b37` |
| **LotteryAdmin** | `0x0dCDfaBeA5a134B5d42A3a3BCbdb19e82181EF0A` |
| **commit** | `728d3dd8b830f51cb4286d128a07e65c832f374e` |
| 部署日期 | 2026-08-13 |
| 含有 | 原生 ETH、claimTo、Q9 方案 B（LotteryAdmin）+ C（弃期退款）、FR-C-30 开奖激励 |
| Basescan | 已验证（Lottery + LotteryAdmin） |

`Lottery` 构造参数：

| # | 参数 | 值 |
|---|---|---|
| 0 | vrfCoordinator | `0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE` |
| 1 | subId | *（见 `contracts/.env` 的 `VRF_SUBSCRIPTION_ID`）* |
| 2 | keyHash | `0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71` |
| 3 | ticketPrice | `100000000000000`（0.0001 ether） |
| 4 | **anchorTime** | **`1786709230`** |
| 5 | intervals | `[7200]`（快节奏测试实例） |
| 6 | treasury | `0xA7b454432E0Ffe2e9C394c6045ec652e3b1e743f` |
| 7 | feeBps | `100`（1%） |
| 8 | tierBps | `[6000,2500,1500]` |
| 9 | tierWinnerCounts | `[1,2,5]` |

`LotteryAdmin` 构造参数：`(lottery, initialOwner)` =
（上面的 Lottery 地址, `0xA7b454432E0Ffe2e9C394c6045ec652e3b1e743f`）

### 历史实例（已弃用，勿再使用）

| 地址 | commit | 说明 |
|---|---|---|
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
