# 链上周期彩票 — 需求规格说明书

版本 v1.1 · 测试网先行，主网视合规评估 · 目标链：Base Sepolia → Base

---

## 0. 阅读约定

- 需求编号格式 `FR-<模块>-<序号>`，可在提示词里直接引用（例如「实现 FR-C-07」）
- **MUST** = 必须实现；**SHOULD** = 建议；**MUST NOT** = 明确禁止
- 每条需求后的「验收」是可写成测试的判定条件

---

## 1. 项目目标与非目标

### 1.1 目标

做一个可在测试网完整跑通的周期开奖彩票，用于练习：Solidity 状态机设计、
Chainlink VRF/Automation 集成、gas 优化、Foundry 测试（含 fuzz 与不变量测试）、
以及 wagmi/viem 前端对接。

### 1.2 非目标（明确不做，不要自作主张加）

- **MUST NOT** 引入任何可升级代理（UUPS / Transparent / Beacon）
- **MUST NOT** 做 KYC、地理封锁、法币出入金
- **MUST NOT** 做推荐返佣、代币激励、NFT 门票
- **MUST NOT** 做后端数据库；历史数据一律从链上事件读取
- 不做移动端 App，不做多语言

---

## 2. 术语

| 术语 | 含义 |
|---|---|
| Round（期） | 一个完整的售票→开奖→领奖周期，用 `roundId`（uint32，从 1 开始）标识 |
| Ticket（票） | 一期内的最小投注单位，用 `ticketId`（uint32，每期内从 0 递增）标识 |
| Range（票区间） | 一次购买产生的连续票号区间 `[start, end)`，同一 owner |
| Pot（奖池） | 该期扣除运营抽成后的可分配金额 |
| Tier（奖级） | 一等奖 / 二等奖 / 三等奖 |
| Keeper | Chainlink Automation 的执行者 |

---

## 3. 系统架构

```
┌─────────────┐   wagmi/viem   ┌──────────────────┐
│  Next.js    │ ─────────────► │  Lottery.sol     │
│  前端       │ ◄───────────── │  (Base)          │
└─────────────┘  读事件/状态   └──────────────────┘
                                   ▲          ▲
                          VRF v2.5 │          │ Automation
                                   │          │
                            ┌──────┴──────────┴──────┐
                            │   Chainlink 网络       │
                            └────────────────────────┘
```

三个交付物：`contracts/`（Foundry）、`web/`（Next.js）、`docs/`。

---

## 4. 合约层需求（FR-C）

### 4.1 计价与资产

- **FR-C-01** 奖池资产 **MUST** 使用 ERC20（部署时通过构造参数注入 token 地址），
  默认 USDC。**MUST NOT** 硬编码 6 位小数——所有金额按 token 原生精度处理，
  票价由构造参数给出。计价 token **MUST** 是标准 ERC20：**MUST NOT** 使用
  转账扣费（fee-on-transfer）或弹性供给（rebasing）代币——名义记账与实际到账不符
  会击穿偿付性不变量（2026-08-09 安全自查 #4）。部署默认票价 = 1 个计价 token（USDC 即 1e6，
  Deploy 脚本按 decimals 换算，2026-08-07 定）。
  - 验收：用 6 decimals 和 18 decimals 两种 mock token 分别跑全套测试均通过
- **FR-C-02** 所有 ERC20 交互 **MUST** 使用 OpenZeppelin `SafeERC20`
- **FR-C-03** 合约 **MUST NOT** 接收原生币（无 `receive` / `payable`）

### 4.2 票务与存储

- **FR-C-04** 一次 `buyTickets(uint32 quantity)` **MUST** 只写入一条 Range 记录，
  而非逐张写入。数据结构：
  ```solidity
  struct TicketRange { uint32 start; uint32 end; address owner; } // [start, end)
  mapping(uint32 roundId => TicketRange[]) ranges;
  ```
  - 验收：`buyTickets(100)` 的 gas **MUST** 低于 `buyTickets(10)` 的 3 倍
- **FR-C-05** 由 `ticketId` 反查 owner **MUST** 用二分查找，复杂度 O(log n)
  - 验收：fuzz 测试，任意 ticketId < ticketCount 都能查到正确 owner
- **FR-C-06** 单次购买数量 **MUST** 有上限（`MAX_TICKETS_PER_TX`，建议 1000），
  防止 uint32 溢出和单笔过大
- **FR-C-07** 每期总票数 **MUST** 不超过 `type(uint32).max`

### 4.3 状态机

- **FR-C-08** 每期状态 **MUST** 严格遵循：
  ```
  OPEN ──(block.timestamp >= drawTime, keeper 触发)──> DRAWING
  DRAWING ──(VRF 回调)──> SETTLED
  OPEN ──(ticketCount == 0)──> VOIDED        // 不消耗 VRF 请求
  ```
  其中 `drawTime = closeTime + SEAL_GAP`，`SEAL_GAP` **MUST** 是 `constant`
  （75 分钟），对应双色球「20:00 停售、21:15 开奖」的间隔。
  closeTime 到 drawTime 之间为封盘期：状态仍是 OPEN，但购票已被 FR-C-09 拒绝
- **FR-C-09** `buyTickets` 在 `state != OPEN` 或 `block.timestamp >= closeTime` 时
  **MUST** revert（即使 keeper 还没跑）
  - 理由：防止有人卡在截止边缘、已知即将开奖时下注
- **FR-C-10** 发起 VRF 请求后 **MUST** 立即开启下一期，不等回调
  - 验收：`performUpkeep` 后 `currentRound` 已 +1 且新期可购票

### 4.4 随机数与开奖

- **FR-C-11** 随机数 **MUST** 来自 Chainlink VRF v2.5（`VRFConsumerBaseV2Plus`）。
  **MUST NOT** 使用 `block.timestamp` / `blockhash` / `block.prevrandao` 参与
  中奖号码计算
- **FR-C-12** 多奖级中奖票号由单个 `randomWord` 派生：
  ```solidity
  ticketId_tier_i = uint256(keccak256(abi.encode(seed, i))) % ticketCount
  ```
  其中 i=0 为一等奖，i=1..N 为后续奖级。
  **允许同一票号中多个奖级**（概率约 k/n，极低）——这是刻意接受的简化，
  **MUST** 有测试显式覆盖这种情况而非规避它
- **FR-C-13** 奖级分配比例 **MUST** 可在构造时配置，且各级比例之和 **MUST** 等于
  10000 bps。默认：一等奖 60%、二等奖 25%（2 名均分）、三等奖 15%（5 名均分）
- **FR-C-14** VRF 超时兜底：`retryDraw(roundId)` **MUST** 满足
  - 任何人可调用（不限 owner）
  - **MUST** 距上次请求满 `DRAW_TIMEOUT`（3 小时）
  - **MUST** 仍处于 DRAWING 状态
- **FR-C-15** `fulfillRandomWords` **MUST** 在 `state != DRAWING` 时静默 return
  - 理由：重试后旧请求迟到返回，绝不能改写已定结果
  - 验收：必须有专项测试模拟「新请求先落地、旧请求后到」
- **FR-C-16** `fulfillRandomWords` 内 **MUST NOT** 有循环上限不确定的操作、
  外部调用、或转账。只做记账

### 4.5 领奖与资金

- **FR-C-17** **MUST** 采用 pull 模式：中奖者调用 `claim(roundId, tier)` 领取
- **FR-C-18** `claim` **MUST** 遵循 Checks-Effects-Interactions，且 **MUST** 加
  `ReentrancyGuard`
- **FR-C-19** 领奖窗口 `CLAIM_WINDOW` = 90 天（自该期 `closeTime` 起算）。
  超期后 `rolloverExpired(roundId)` **MUST** 允许任何人把未领奖金滚存进当前期奖池
- **FR-C-20** 运营抽成 **MUST** 与奖池分账记录（独立的 `accruedFees` 变量）
  - 验收：提走全部 fees 后，各期 pot 之和不变，合约余额仍 ≥ 所有未领奖金
- **FR-C-21** 抽成比例上限 `MAX_FEE_BPS` **MUST** 是 `constant`（1000 = 10%），
  owner 也无法突破。部署默认 `feeBps` **MUST** 为 100（1%）（2026-08-07 定）
- **FR-C-26** 冷启动注资（2026-08-07 增）：**MUST** 提供
  `injectPot(uint32 roundId, uint256 amount)`，任何人可向处于 OPEN 状态的期
  注入 token，全额计入该期 pot、不抽成，SafeERC20 收款并 emit `PotInjected`。
  注入只进不出，**MUST NOT** 存在对应的取回函数（与 FR-C-24 一致）。
  若该期最终 VOIDED（零购票），已注入金额 **MUST** 滚入下期奖池并
  emit `PrizeRolledOver`
  - 验收：注资后该期 pot 增加、`accruedFees` 不变；VOIDED 期的注资滚入下期

### 4.6 权限与暂停

- **FR-C-22** owner 的**业务**权限仅限：设置 treasury、设置 feeBps（≤上限）、暂停售票。
  另有两类**继承而来、无法封禁**的权限，2026-08-09 安全自查后在此显式披露：
  - `transferOwnership` / `acceptOwnership`（来自 ConfirmedOwner）
  - `setCoordinator`（来自 VRFConsumerBaseV2Plus，非 virtual 无法 override）。
    合约已把 coordinator 钉死为 immutable：请求恒发往钉死地址，回调强制校验
    随机源未被替换（`CoordinatorTampered`）。**owner 换源无法操纵开奖或挪用资金**，
    最坏只能造成可自行恢复的结算延迟
  - 验收：`test/LotteryVrfHijack.t.sol` 证明劫持随机源后回调被拒、奖池分文未动
- **FR-C-23** `setSalesPaused(true)` **MUST** 只影响 `buyTickets`。
  `claim` / `rolloverExpired` / `retryDraw` **MUST** 不受影响
  - 验收：暂停状态下中奖者仍能成功领奖
- **FR-C-24** **MUST NOT** 存在任何形式的 `emergencyWithdraw` / `sweep` /
  `rescueTokens`，能动到未领奖金

### 4.7 事件

- **FR-C-25** 以下事件 **MUST** 齐备，且索引字段足以让前端仅靠事件重建全部历史：
  ```
  RoundOpened(uint32 indexed roundId, uint64 closeTime)
  TicketsBought(uint32 indexed roundId, address indexed buyer, uint32 start, uint32 quantity)
  PotInjected(uint32 indexed roundId, address indexed sender, uint256 amount)
  DrawRequested(uint32 indexed roundId, uint256 indexed requestId)
  WinnersPicked(uint32 indexed roundId, uint32[] winningTickets, address[] winners)
  PrizeClaimed(uint32 indexed roundId, address indexed winner, uint8 tier, uint256 amount)
  PrizeRolledOver(uint32 indexed fromRound, uint32 indexed toRound, uint256 amount)
  RoundVoided(uint32 indexed roundId)
  ```

---

## 5. 测试需求（FR-T）

- **FR-T-01** 行覆盖率 **MUST** ≥ 90%（`forge coverage`）
- **FR-T-02** **MUST** 包含以下 fuzz 测试：
  - 中奖者永远是本期真实持票人
  - 任意 ticketId 二分查找结果 == 线性扫描结果
  - 两种 decimals 的 token 下账目一致
- **FR-T-03** **MUST** 包含 Foundry 不变量测试（`invariant_`），至少覆盖：
  - `合约 token 余额 >= 所有未领奖金 + accruedFees`
  - `sum(各期 pot) + accruedFees + 已支付总额 == 历史购票总额 + 历史注资总额`
- **FR-T-04** **MUST** 包含以下攻击场景测试：
  - 重入 `claim`（用恶意 ERC20 回调）
  - 旧 VRF 回调覆盖新结果
  - `closeTime` 边界抢跑购票
  - owner 试图把 feeBps 设到上限以上
- **FR-T-05** **MUST NOT** 通过修改测试断言来让实现通过。若测试与规格冲突，
  停下来报告冲突

---

## 6. 前端需求（FR-W）

技术栈：Next.js (App Router) + TypeScript + wagmi v2 + viem + RainbowKit + Tailwind

- **FR-W-01** 首页 **MUST** 展示：当前期号、当前奖池、倒计时、票价、我的持票数
- **FR-W-02** 购票流程 **MUST** 正确处理 ERC20 两步：先检查 allowance，
  不足则先 `approve`，再 `buyTickets`。两笔交易都要有独立的 pending/成功/失败状态
- **FR-W-03** **MUST** 有「我的记录」页：从 `TicketsBought` 和 `PrizeClaimed`
  事件读取当前地址的历史，不依赖任何后端
- **FR-W-04** 若当前地址在某期中奖且未领取且未过期，**MUST** 显著提示并提供
  一键领奖按钮
- **FR-W-05** 所有链上写操作 **MUST** 在发起前检查链 ID，错链时提示切换
- **FR-W-06** **MUST** 处理两个中间态，界面不得卡在倒计时 00:00：
  - closeTime ~ drawTime 之间（封盘期）：显示「已封盘，21:15 开奖」及剩余时间
  - drawTime 已到但 keeper 未执行 / VRF 未回调：显示「开奖中」
- **FR-W-07** 合约 ABI 与地址 **MUST** 从单一配置文件导出，不散落在组件里

---

## 7. 部署与运维（FR-D）

- **FR-D-01** **MUST** 提供 `Deploy.s.sol`，按 `block.chainid` 区分网络配置
- **FR-D-02** 部署脚本 **MUST** 在结尾打印待办清单：加 VRF consumer、
  注册 Automation upkeep
- **FR-D-03** **MUST** 提供 `Interact.s.sol` 用于测试网手动触发：购票、
  强制推进时间（本地）、查询期状态
- **FR-D-04** 敏感值（私钥、RPC、订阅 ID）**MUST** 从环境变量读取，
  **MUST NOT** 出现在任何提交的文件里。**MUST** 提供 `.env.example`

---

## 8. 里程碑

| 阶段 | 交付 | 完成判定 |
|---|---|---|
| M1 | 合约核心 + 单元测试 | FR-C-01~26 全部实现，`forge test` 全绿 |
| M2 | Fuzz + 不变量 + 攻击测试 | FR-T-01~04 达标，coverage ≥ 90% |
| M3 | 部署脚本 + Base Sepolia 部署 | 测试网完整跑通一期：购票→开奖→领奖 |
| M4 | 前端 | FR-W-01~07 实现，能连测试网完成购票和领奖 |
| M5 | 打磨 | gas report 优化、README、NatSpec 补全 |

---

## 9. 已决策问题（2026-08-07 拍板，实现时直接照此执行）

- **Q1（票数不足奖级名额）**：参照双色球「未中出奖级奖金滚存、计入下期一等奖」
  的逻辑。当本期 `ticketCount` 小于某奖级的名额数时，该奖级本期**不开出**，
  其对应奖金滚入下期，并计入**下期一等奖份额**；名额数 ≤ `ticketCount` 的奖级
  照常开出（FR-C-12 允许的同票跨奖级重复中奖不受影响）。
  - 验收：`ticketCount == 3` 时，一等奖（1 名）、二等奖（2 名）照常开出，
    三等奖（5 名）不开出，其 15% 奖金滚入下期一等奖份额，
    并 emit `PrizeRolledOver(fromRound, toRound, amount)`
- **Q2（closeTime 锚点，2026-08-07 更新：日程与双色球一致）**：锚定固定日程，
  复刻双色球——每周二、四、日开奖：北京时间 20:00 停售（`closeTime`）、
  21:15 开奖（`drawTime`，见 FR-C-08）。即 closeTime 场次为每周二/四/日
  12:00 UTC，场次间隔循环 `[2 天, 3 天, 2 天]`（二→四→日→二）。
  实现：构造时注入锚点时间戳（某个周二 12:00 UTC）与间隔数组，链上循环推进。
  新期 closeTime **MUST** 取日程中晚于当前时刻的最近一个场次（极端延迟时
  跳过已错过的场次），与 keeper 实际执行时刻无关，不产生累积漂移
- **Q3（同址多次购票）**：允许。同一地址同期多次购买产生多个 Range，
  不做去重检查
- **Q4（票价，2026-08-07）**：部署默认 1 USDC（见 FR-C-01）
- **Q5（奖级结构，2026-08-07）**：确认维持 FR-C-13 默认——60% / 25% / 15%，
  1 / 2 / 5 名
- **Q6（冷启动注资，2026-08-07）**：增加任何人可调用的 `injectPot`
  （见 FR-C-26），用于运营方做大奖池和活动派奖
- **Q7（项目定位，2026-08-07）**：测试网先行完整验证；是否上主网取决于
  合规评估（牌照、运营主体所在司法辖区）结果
- **Q8（keeper 方案，2026-08-08）**：Chainlink Automation 已被官方弃用
  （测试网 2026-06-24 停服，主网 2026-07-31，替代品为 CRE）。合约的
  checkUpkeep/performUpkeep 接口不变——keeper 本就不在信任边界内
  （performUpkeep/retryDraw 任何人可调，随机数安全仅依赖 VRF）。
  测试阶段用自托管轮询 keeper 触发开奖；主网前迁移到 CRE 定时工作流
