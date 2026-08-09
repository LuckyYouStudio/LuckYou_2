# LuckYou 安全自查报告

日期：2026-08-09 · 范围：`contracts/src/Lottery.sol`、`contracts/src/cre/LotteryKeeperReceiver.sol`
方法：Slither 0.11.6 静态分析 + 敌对视角人工代码复查 + PoC 验证
性质：**自查，非第三方审计**。主网前仍必须做独立第三方审计。

## 执行摘要

发现 **1 个 Critical**（已修复并有回归测试坐实）、1 个 Medium（经济设计，待决策）、
2 个 Low、5 个提示项。Slither 报出的 2 个 Medium 经逐行验证**均为误报**。

合约的记账数学、状态机、二分查找、滚存与舍入守恒经逐项验算**未发现缺陷**；
真正的问题出在**继承链带来的权限面**——这正是自测最容易漏掉的盲区。

| # | 严重度 | 问题 | 状态 |
|---|---|---|---|
| 1 | **Critical** | owner 可经继承的 `setCoordinator` 替换随机源，操纵开奖稳赢奖池 | ✅ 已修复 + PoC 回归 |
| 2 | Medium | 注资/滚存奖池在低参与度下可被单一大户整包捕获 | ⏳ 待决策（经济设计） |
| 3 | Low | 卡在 DRAWING 的期不被 keeper 感知，需人工 `retryDraw` | ⏳ 待决策（方案见下） |
| 4 | Low | 隐含假设标准 ERC20，扣费/弹性代币会击穿偿付性 | ✅ 已在 NatSpec 明确约束 |
| 5 | Info | `injectPot` 封盘后仍可注资，与购票时间闸不一致 | ✅ 已修复 + 测试 |
| 6 | Info | 结算后 `r.pot` 不清零，`getRound` 返回旧值 | ✅ 判定为设计如此（历史信息） |
| 7 | Info | `s_totalSlots` 死存储 | ✅ 已删除 |
| 8 | Info | 回调内 `_deriveWinners` 的 gas 曲线与 FR-C-16 软冲突 | 📋 已知权衡（见下） |
| 9 | Info | `_openNextRound` 日程追赶循环理论无界 | 📋 实际不可达 |

---

## 1. Critical — owner 可劫持随机源操纵开奖【已修复】

### 问题

`Lottery` 继承 `VRFConsumerBaseV2Plus`，后者暴露：

```solidity
function setCoordinator(address _vrfCoordinator) external override onlyOwnerOrCoordinator
```

**owner 可调，且该函数不是 `virtual`——无法在子合约 override 封禁**。而请求与回调
原本都以可变的 `s_vrfCoordinator` 为唯一信任锚。

### 攻击路径（已用 PoC 实测跑通）

1. owner 部署假 coordinator（`requestRandomWords` 返回任意 id，可主动回调）
2. owner 调 `setCoordinator(假)`
3. owner 买 1 张票，正常触发开奖
4. owner **离线暴力挑选种子**，使 `keccak256(seed, 0) % ticketCount` 等于自己的票号
5. 假 coordinator 用挑好的种子回调 → owner 稳中一等奖 → `claim` 提走

**PoC 实测结果**：受害者投入 99 USDC、攻击者投入 1 USDC，攻击者提走 59.4 USDC。
无需任何 VRF 订阅费。

### 为什么是盲区

SPEC 的 FR-C-11（随机数必须来自 VRF）、FR-C-22（owner 权限仅三项）、
FR-C-24（无任何资金后门）三条信任声明**全部被这一条继承函数推翻**，
而原有的 `test_Attack_OwnerCannotExceedFeeCapNorTouchPot` 只验证了「owner 不能直接搬走奖池」，
恰好漏掉了「owner 能通过操纵开奖合法地赢走奖池」这条路径。

### 修复

由于基类函数非 virtual 无法封禁，改用**钉死 + 校验**：

1. 构造时把 coordinator 存入 `address private immutable i_coordinator`
2. `_requestRandomWords` 恒发往 `i_coordinator`，不受 `setCoordinator` 影响
3. `fulfillRandomWords` 开头强制校验
   `address(s_vrfCoordinator) == i_coordinator`，否则 `revert CoordinatorTampered()`

**修复后的剩余风险**：owner 换源仍会让真 coordinator 的回调被基类拒绝，
造成该期延迟结算（owner 换回即恢复，且 `retryDraw` 任何人可调）。
即 **Critical（资金被盗）降级为可自行恢复的延迟**，资金绝对安全。
此权限已在合约 NatSpec 与 SPEC FR-C-22 中显式披露。

**回归测试**：`test/LotteryVrfHijack.t.sol` 三例——劫持后回调被拒且奖池分文未动、
请求恒发往钉死地址、正常流程不受影响。

---

## 2. Medium — 注资/滚存奖池可被单一大户整包捕获【待决策】

`injectPot`（Q6 运营做盘）与 `tier1Carry`（Q1 滚存）累积的「白送的钱」，
归属完全取决于谁买的票多。在冷启动/低参与度下：

攻击者盯住一个被注资或滚存做大、但无人问津的期，在停售前买满 ≥ 全部奖级名额（默认 8 张），
成为唯一买家 → 持有全部票号 → **必中所有奖级**（与随机数无关）→ 把整包奖池赢回。
净收益 ≈ 注资额 + 滚存额 − 自己那几张票的 1% 手续费，是**正期望值攻击**。

这部分属于滚存彩票的固有经济特性（Q1 本就是这么设计的），但 SPEC 从未分析过
「单一买家捕获注资」这一面，`injectPot` 尤其把运营资金直接暴露给套利者。

**候选缓解**（需你拍板，涉及 Q1/Q6 决策）：
- (a) 注资仅在本期票数达到某阈值时才计入可分配额，否则顺延
- (b) 单一地址中奖占比封顶
- (c) 不改代码，只在运营纪律上规定「注资只在有一定参与度时投放」
- (d) 接受现状（测试网无实际损失）

---

## 3. Low — 卡死在 DRAWING 的期无 keeper 兜底【待决策】

`checkUpkeep` 只检查 `s_currentRound`（永远是 OPEN 的那期）。一旦某期进入 DRAWING
而 VRF 请求丢失，它已不是当前期，自动 keeper（含 CRE 工作流）**永远不会为它做任何事**，
其奖池被冻结直到有人手工调 `retryDraw`。

VRF 可靠时几乎不发生，且任何人可救，但属真实的活性缺口。

**候选修复**：`checkUpkeep` 增加对超时 DRAWING 期的扫描，用 `performData` 区分动作，
`performUpkeep` 据此调用 `retryDraw`。代价：需同步更新 CRE 工作流与自托管 keeper 脚本。

---

## 4~9. 其余发现

- **#4（已处理）**：合约 NatSpec 现已明确「仅支持标准 ERC20，不支持 fee-on-transfer /
  rebasing」——这类代币会使名义记账与实际到账不符，击穿偿付性不变量。
- **#5（已修复）**：`injectPot` 现与 `buyTickets` 共用同一时间闸（`closeTime` 后拒绝），
  新增测试 `test_RevertWhen_InjectAfterCloseTime`。
- **#6（判定为设计如此）**：SETTLED 期的 `r.pot` 保留原值是**有意义的历史信息**
  （「该期奖池曾是多少」），实际记账走 `perWinnerAmount`/`claimedBits`，不影响资金安全。
- **#7（已修复）**：删除从未被读取的 `s_totalSlots`，省一次 SSTORE。
- **#8（已知权衡）**：回调内 `_deriveWinners` 的 gas ≈ slots(≤16) × log2(ranges)，
  只有在单期 ranges 达数百万条时才逼近 1M 回调上限（经济上不现实）。
  保留它是因为 FR-C-25 要求 `WinnersPicked` 事件让前端仅靠事件重建历史。
- **#9（实际不可达）**：日程追赶 do-while 的迭代次数需数百年无人调用才会撞 gas 上限，
  而 `performUpkeep` 无权限任何人可推进。

---

## Slither 静态分析结果

29 条发现，**零 High/Critical**。两个 Medium 逐行验证后**均为误报**：

- `divide-before-multiply`（第 327~329 行）：`amount - perWinner * winners` 是**刻意的求余数写法**，
  恒等于 `amount % winners`，不损失精度，余数正确滚入下期
- `reentrancy-no-eth`（`performUpkeep`/`retryDraw`）：VRF 请求前状态已先行落定
  （先设 DRAWING、先更新时间戳），任何重入回路都会撞状态检查 revert——标准 CEI 顺序

其余为 Low（timestamp 依赖，刻意设计）与命名规范提示（`s_`/`i_` 前缀是本项目规范，
与 Slither 默认的 mixedCase 冲突，不改）。完整清单见同目录 `slither-report.md`。

---

## 经复查确认**没有**问题的点

- **旧 VRF 回调覆盖新结果**：双闸（state + requestId 匹配）严密，乱序到达均被静默丢弃
- **滚存守恒**：`distributed + carryOut == pot + tier1Carry` 逐项验算无泄漏；
  比例舍入 dust 与均分余数都并入 carryOut；carry 恒落到当前 OPEN 期，永不冻结
- **二分查找**：ranges 连续分区，边界正确，空数组下溢路径不可达
- **领奖与位图**：per-slot 标记杜绝重复领取；claim 与 rolloverExpired 时间窗互斥无重叠；
  CEI + `nonReentrant`，恶意 token 回调重入已被测试证伪
- **封盘抢跑**：种子在停售 75 分钟后才产生，买票期内不可知，无法卡点下注
- **owner 直接搬奖池**：确无 `sweep`/`emergencyWithdraw`，资金出口只有中奖者与 treasury

---

## 结论与后续

- 测试数：69 个全绿；`Lottery.sol` 行覆盖 99.26%、分支 91.07%
- **已部署的测试网实例 `0x928C…75Aa` 是修复前的版本**，含 Critical 漏洞。
  测试网无真实资金，但演示前建议重新部署修复版
- 主网前仍需：第三方独立审计 → 合规（牌照/运营主体）
