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
- **MUST NOT** 做推荐返佣、NFT 门票
- **MUST NOT** 发行任何代币（2026-08-13 澄清）。此前此处笼统写「代币激励」，
  与 FR-C-30 的开奖奖励产生歧义——后者以**原生币**支付、资金来自运营抽成，
  是**购买运维服务**而非参与激励，不在禁止之列。禁止的是发币、返佣、门票 NFT
  这类改变代币经济结构的东西
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

- **FR-C-01**（2026-08-11 重大变更：由 ERC20/USDC 改为**原生 ETH**）
  奖池资产 **MUST** 使用链原生币（ETH），**MUST NOT** 使用任何 ERC20。
  部署默认票价 **MUST** 为 `0.0001 ether`（1e14 wei），由构造参数给出。
  - **变更理由**：USDC 由 Circle 发行，合约可暂停、可黑名单、可升级。若合约地址
    被列入黑名单，买票/领奖/提抽成同时失效且 FR-C-24 禁止任何救援手段（第十轮红队 #11）。
    原生 ETH 无发行方、无此风险；同时省掉 approve 步骤，用户从两笔交易降为一笔
    （实测省约 56% gas，更重要的是消除了「approve 成功但购票失败」的中间态）
  - **已知代价（刻意接受）**：ETH 价格波动会影响奖池实际购买力。彩票资金
    停留时间长（单期数日 + 90 天领奖窗口 + 跨期滚存），**这是本方案最大的缺点**，
    优先于任何 gas 考量。票价以 ETH 计价，法币票价随行情浮动
  - 验收：全套测试在原生 ETH 下通过；合约不持有任何 ERC20
- **FR-C-02**（2026-08-11 重写）所有资金转出 **MUST** 使用 `call{value:}` 并**检查返回值**，
  失败即 revert（`TransferFailed`）。**MUST NOT** 使用 `transfer`/`send`（2300 gas 上限
  会让多签等合约钱包无法收款）
- **FR-C-03**（2026-08-11 推翻原条款）合约 **MUST** 通过 `payable` 函数接收原生币，
  且仅限 `buyTickets` 与 `injectPot` 两个入口。
  - **MUST NOT** 提供 `receive()` / `fallback()`：误转入的 ETH 无法退回，还会破坏
    「合约余额 == 全部债务」的偿付性不变量（第十轮红队 #11 曾就 ERC20 误转指出同一问题）
  - **MUST** 精确校验 `msg.value`：`buyTickets` 要求恰好等于 `票价 × 张数`，
    多付即 revert（`IncorrectPayment`）。**MUST NOT** 自动退还差额——退款是一次
    额外的外部调用，会平白扩大重入面
  - **重入**：原生转账会执行接收方代码（ERC20 转账不会）。所有转出路径
    **MUST** 遵循 CEI 且加 `nonReentrant`

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
  closeTime 到 drawTime 之间为封盘期：状态仍是 OPEN，但购票已被 FR-C-09 拒绝。
  - **最短售票窗口（2026-08-10 第三轮自查 #2）**：新期 closeTime **MUST** 距开期时刻
    至少 `MIN_SALES_WINDOW`（30 分钟，`constant`），不足则跳到下一场次；
    构造参数的场次间隔 **MUST** 大于 `SEAL_GAP + MIN_SALES_WINDOW`。
    理由：`performUpkeep` 无权限、任何人可择时调用，若无下限，调用者可卡在下一场次前
    1 秒开期，使新期仅有 1 秒售票窗口供自己独占（同时并解旧发现 H）
  - **锚点必须落在过去（2026-08-14 第 50 轮 A-4 增）**：`anchorTime` **MUST**
    `<= block.timestamp`，且 **MUST** 不早于 `block.timestamp - 365 days`（R20 L-4）。
    两侧都是致命的、且都不可修复（日程全合约无 setter，FR-C-24 又禁止救援手段）：
    过老 ⇒ 构造时的追赶循环 OOG，部署直接失败（吵闹、无害）；
    **落在未来 ⇒ 第 1 期的 closeTime 也落在未来，`performUpkeep` 永远不到期、
    期号永不推进，而 `buyTickets` 只看 state 与 closeTime，实例会照常收钱**（安静、致命）。
    锚点按定义就是「一个已经发生过的场次」，因此这道闸不会拒绝任何合法配置
  - 验收：keeper 缺席时择时调用 `performUpkeep`，新期售票窗口仍 ≥ MIN_SALES_WINDOW；
    `test/AuditR50Poc.t.sol::test_RevertWhen_AnchorIsInTheFuture`
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
  - **MUST** 另提供 `claimTo(roundId, tier, to)`（2026-08-11 增，R20 M-1）：
    中奖判定恒以 `msg.sender` 持票为准，`to` 只决定钱付到哪里，**不增加任何权限面**。
    存在的理由是原生 ETH 改造引入的一类弃奖：没有 `receive`/`fallback` 的合约钱包
    中奖后 `claim` 恒 revert `TransferFailed`，90 天后奖金被 `rolloverExpired` 扫走。
    `to` **MUST NOT** 为零地址
- **FR-C-18** `claim` **MUST** 遵循 Checks-Effects-Interactions，且 **MUST** 加
  `ReentrancyGuard`
- **FR-C-19** 领奖窗口 `CLAIM_WINDOW` = 90 天，**自该期实际结算时刻 `settledAt` 起算**
  （2026-08-10 第四轮自查：原按 `closeTime` 起算，keeper/VRF 停摆超 90 天时中奖者
  会被判 0 且奖金被第三方扫走）。超期后 `rolloverExpired(roundId)` **MUST** 允许任何人
  把未领奖金**转入滚存缓冲区**（见 FR-C-28），**MUST NOT** 直接注入当前期——
  当前期可能已封盘、票已冻结，攻击者可预先卡位独占（第二轮 High A）
  - 验收：停摆 91 天后结算，中奖者仍可领奖；第三方在此之前无法 rollover
- **FR-C-20** 运营抽成 **MUST** 与奖池分账记录（独立的 `accruedFees` 变量）。
  抽成的一部分**可**流向触发开奖者（FR-C-30）——但那仍在抽成侧，
  **奖池分文不动**这一条不受影响
  - 验收：提走全部 fees 后，各期 pot 之和不变，合约余额仍 ≥ 所有未领奖金
- **FR-C-21** 抽成比例上限 `MAX_FEE_BPS` **MUST** 是 `constant`（1000 = 10%），
  owner 也无法突破。部署默认 `feeBps` **MUST** 为 100（1%）（2026-08-07 定）
- **FR-C-28** 滚存缓冲区（2026-08-10 第二/四轮自查增）：`s_pendingPot` 与
  `s_pendingTier1` **MUST** 作为滚存资金的中转站。入口三处：过期滚存（FR-C-19）、
  未开出奖级的 carry（Q1）、超出配比被扣留的部分（FR-C-27）；出口唯一：
  `_openNextRound` 在开出新期时消费。
  - **释放受两道等比例约束**（都不是 0/1 阈值——阈值会造成永久冻结，本项目已踩过三次）：
    1. **窗口完整度打折**：释放额 = 缓冲余额 × (实际售票窗口 / 名义窗口)，按 bps 计算。
       `performUpkeep` 无权限、开期时刻由调用者选，攻击者可拖到临近场次才开期、
       在同一笔交易内买光独占；打折使压缩窗口等比例削减本期可捕获额度。
       **MUST NOT** 改回硬阈值：那会在 keeper 持续不及时时把缓冲卡死。
       **MUST** 用 bps 而非百分比——百分比整数除法在名义窗口远大于实际窗口时
       （正式日程「3 天」腿达 70.75 小时）会归零，等价于硬阈值
    2. **自售额配比**（FR-C-27）
  - VOIDED 期的资金 **MUST** 同样经缓冲区转出，**MUST NOT** 直接注入下一期——
    否则攻击者可让期空转、再在压缩窗口时触发 VOID，使整包 carry 绕过打折规则
  - 事件语义：资金进缓冲发 `PrizeRolledOver(fromRound, 0, amount)`（`toRound` 恒为 0，
    因为打折释放可能分多期落地、此刻去向未定）；真正释放发
    `CarryReleased(toRound, potAmount, tier1Amount)`
  - 缓冲区余额 **MUST** 计入偿付性不变量（FR-T-03）
  - 因 FR-C-10「开奖即开下一期」，某期结算产生的 carry 实际落在**再下一个新开出的期**，
    而非紧邻的下一期
  - 验收：`test/LotteryCarryTiming.t.sol`、`test/LotteryCarryEscape.t.sol`

- **FR-C-27** 滚存/注资的释放配比（2026-08-10 第三轮增、第四轮重做）：
  本期可分配的 carry 上限 **MUST** = 本期自售净额 × `CARRY_MATCH_MULTIPLIER`（1），
  超出部分退回缓冲区顺延（FR-C-28）。
  - **演进过程**（两个被 PoC 打穿的方案，记录以免重蹈）：
    ① 阶跃门槛「票数达 100 就全放」——恰好买满门槛即可独占整包，捕获成本与 carry
    规模无关（O(1)），carry 越大越划算；
    ② 加「连续扣留 3 期后强制放行」逃生阀——攻击者用 1 张票攒计数器，
    成本降到 8 USDC 吃掉 10000 USDC（**第四轮 Critical**）
  - 现行配比制使资本门槛与捕获量线性挂钩，且只要有人买票就释放对应额度，
    不会像阶跃门槛那样在低参与度下把资金永久冻结
  - **诚实的局限**：仍不能消除捕获。买光全场即可拿走全部奖池是抽签制彩票的
    固有性质，攻击者的本金也会随中奖回到自己手里；配比只抬高**单期**的资本门槛
    并给其他参与者稀释的机会
  - ⚠️ **暴露面订正（2026-08-11 R20 H-2）**：此处原写「投 X 至多撬动 X 的 carry」，
    读起来像是「要吃下 10 ETH 的 carry 就得备齐 10 ETH」——**这是对暴露面的实质性低估**。
    「X 换 X」只在**单期内**成立。攻击者的本金随中奖立刻回到手里，因此同一笔钱
    每期复用一次，单期净收益 ≈ 本金（只损耗 1% 抽成）。实测：注资 10 ETH、
    攻击者本金 1 ETH，单期 1 → 1.98 ETH，按官方日程约 3 周抽干，**资本占用恒为 1 ETH**。
    真正的暴露面是**整包缓冲区**，而不是单期的 X。
    - 而且「唯一买家」可以**在链上强制**、零风险：辅助合约在买票前检查
      `ticketCount == 0`，有人参与就整笔回滚，只白付 gas。既有的最短窗口、
      按窗口打折、1:1 配比都只限制**单期捕获量**，不限制**重复次数**。
    - **前提是有效参与度接近零**——任何人买 1 张票就会让那笔交易回滚。所以这不是
      「攻击一个热闹的彩票」，而是「冷清的彩票 + 一笔大额注资」，恰好就是冷启动场景。
    - 最有效的缓解是运营纪律而非代码：见 FR-C-26 的「单次注资不超过一期有机售票额」。
      若要在代码上再压一档，可把 `CARRY_MATCH_MULTIPLIER` 改成 bps 并降到 1 以下，
      把单期净收益从 ≈100% 压到 ≈50%——**这不能消除策略**，只是把抽干时间拉长一倍，
      代价是正常参与者拿到的 carry 也一起减半（产品决策，未实施）
  - 验收：注资 10000、仅买 8 张时至多拿回「本金 + 等额 carry」，其余留在缓冲

- **FR-C-26** 冷启动注资（2026-08-07 增；2026-08-11 随 FR-C-01 改为原生币）：
  **MUST** 提供 `injectPot(uint32 roundId) payable`，任何人可向处于 OPEN 状态的期
  注入原生币，`msg.value` 全额计入该期 pot、不抽成，emit `PotInjected`。
  - **运营纪律（R20 H-2）**：单次注资**不应**远超一期的有机售票额。缓冲区规模一旦
    远大于自然成交量，「唯一买家」策略就必然有利可图（见 FR-C-27 的暴露面说明）。
    大额冷启动**应当**拆成多期小额注入，或等有机成交量上来再注
  注入只进不出，**MUST NOT** 存在对应的取回函数（与 FR-C-24 一致）。
  若该期最终 VOIDED（零购票），已注入金额 **MUST** 经滚存缓冲区转出（FR-C-28），
  emit `PrizeRolledOver(roundId, 0, amount)`；其后按窗口完整度打折释放到新期。
  **MUST NOT** 直接注入下一期（会被「让期空转 + 压缩窗口触发 VOID」绕过打折规则）
  - 验收：注资后该期 pot 增加、`accruedFees` 不变；VOIDED 期的注资滚入下期

### 4.6 权限与暂停

- **FR-C-22** owner 的**业务**权限仅限：设置 treasury、设置 feeBps（≤上限）、暂停售票。
  - **treasury 必须能接收原生币**（2026-08-11 原生 ETH 改造新增的约束）：EOA，或带
    `receive`/`fallback` 且不会 revert 的合约。ERC20 时代转账到任何地址都能成功，
    改用原生币后收款方拒收会让 `withdrawFees` 永久 revert、抽成卡死。
    链上无法预先验证（只有真转一次才知道），故由 owner 自行保证；配错可改回可收款
    地址解冻，**奖池不受影响**（抽成与奖池自购票起分账，FR-C-20）
  - 验收：`test/LotteryNativeEth.t.sol::test_RejectingTreasuryBlocksFeesButNotPrizes`
  另有两类**继承而来、无法封禁**的权限，2026-08-09 安全自查后在此显式披露：
  - `transferOwnership` / `acceptOwnership`（来自 ConfirmedOwner）
  - `setCoordinator`（来自 VRFConsumerBaseV2Plus，非 virtual 无法 override）。
    **2026-08-13（Q9 方案 B 落地）**：钉死方案已废止，随机源改为跟随
    `s_vrfCoordinator`（官方迁移可正常跟随）；换源杠杆改从**权限侧**消除——
    Lottery 的 owner **MUST** 是 `LotteryAdmin`，一个在字节码层面就没有能力发出
    `setCoordinator` 调用的极小合约（无通用 execute、不转发 Lottery 的 transferOwnership）。
    于是 `onlyOwnerOrCoordinator` 的两个分支只剩「合法迁移」一条路。
    - ⚠️ **保护来自部署事实而非合约内校验**：若 owner 仍是 EOA，换源攻击依然成立。
      部署清单 **MUST** 包含移交所有权这一步，且 **MUST** 在部署后回读 `owner()` 确认。
      验收：`test/LotteryVrfHijack.t.sol` 同时覆盖「admin 持有时攻击不成立」与
      「EOA 持有时攻击成立」两个方向
    - ⚠️ **但「最坏只是可自行恢复的延迟」这句话是错的**（2026-08-11 R20 H-1/M-2 订正）。
      `setCoordinator` 的修饰符是 `onlyOwnerOrCoordinator` 而非 `onlyOwner`，
      因此有两条路径会把 `s_vrfCoordinator` 改掉，且**都不可恢复**：
      1. **Chainlink 官方订阅迁移**：`VRFCoordinatorV2_5.migrate(subId, newCoordinator)`
         由**订阅所有者**调用，会遍历全部 consumer 逐个调 `setCoordinator`。
         迁移后回调恒被判为 `CoordinatorTampered`，而请求仍发往旧 coordinator
         （那里的 subId 已被删除）——两条腿同时断，每一期都停在 DRAWING，
         `retryDraw` 也救不回来，**全部奖池永久冻结**。彩票不会报错停摆，
         它会继续正常售票收钱。`i_coordinator` 是 immutable，没有任何重新钉死的办法。
         这不是理论风险：本项目自己就因 Automation 被官方弃用而被迫迁移到 CRE（Q8），
         VRF v2.5 将来同样会有下一代 coordinator。
      2. **owner 私钥丢失或被盗**：攻击者调一次 `setCoordinator(任意地址)` 即可造成
         同样的永久冻结。偷不到钱，但对用户而言「钱永远出不来」与被偷差别不大。
    - **当前的缓解（纪律层，不解决根因）**：
      - VRF 订阅所有者 **MUST** 使用多签，并**绝不可**调用 `migrate`
      - 订阅所有者与彩票 owner **应当**是不同主体
      - owner **MUST** 使用多签
    - **根因修复是未决项，见第 9 节 Q9**
  - 验收：`test/LotteryVrfHijack.t.sol` 证明劫持随机源后回调被拒、奖池分文未动
- **FR-C-23** `setSalesPaused(true)` **MUST** 只影响 `buyTickets`。
  `claim` / `rolloverExpired` / `retryDraw` **MUST** 不受影响
  - 验收：暂停状态下中奖者仍能成功领奖
  - **快照语义（2026-08-10 第三轮自查 #1）**：本期能否购票 **MUST** 在开期时快照定死，
    暂停设置只作用于此后开出的新期。否则 owner 可全程暂停清场、末秒解禁自购，
    成为唯一买家独占整包奖池（PoC：花 8 USDC 赢 106.92）。代价是紧急停售最多延后一期生效
  - 验收：已开出的期被暂停后，他人仍可购票；下一期开出时对所有人（含 owner）一律禁售
- **FR-C-24** **MUST NOT** 存在任何形式的 `emergencyWithdraw` / `sweep` /
  `rescueTokens`，能动到未领奖金。
  - **外部信任方披露（2026-08-10 自查 C，第十轮红队修订）**：以下两类外部依赖
    可使资金无法取出，而合约**刻意不提供**任何行政解冻手段（否则即违反本条）：
    1. **VRF 订阅所有者**。撤走 LINK：请求仍会成功，仅该期停在 DRAWING（`retryDraw`
       可救），影响面为单期。`removeConsumer`：请求失败——**VRF 请求已用 try/catch
       与开期解耦**（第十轮 #1 修复），所以最坏是该期停在 DRAWING 并 emit
       `DrawRequestFailed`，新期照常开出、彩票继续运转；恢复 consumer 后
       任何人可 `retryDraw` 救回。修复前此路径会让期号永不推进、全部资金永久冻结
    2. **L2 本身（2026-08-13 补记）**。本项目跑在 Base 上——一条由 Coinbase 运营的
       OP Stack Optimistic Rollup，**不是 L1**。这带来两条此前未被列出的依赖：
       - **排序器（sequencer）是中心化的**。它可以审查或重排交易；宕机则整条链停摆，
         彩票随之停摆（开奖延迟、缓冲区释放比例下降）。有基于 L1 的强制包含通道，
         但慢且不好用。实际影响有限——停几小时几天只是延迟，且 FR-C-29 的 30 天
         弃期退款是最终兜底——但「我们依赖 Coinbase 的排序器正常运转」这句话
         应当白纸黑字写出来，而不是默认所有人都知道
       - **跨链桥合约**。Base 上的每一个 ETH 都由 L1 桥合约里锁着的等量 ETH 背书。
         桥若被攻破，合约里持有的资产会失去支撑。这是选择 L2 换取「gas 便宜三个
         数量级」所付的代价——0.0001 ETH 的票价在以太坊主网上光 gas 就比票价贵
    3. ~~**计价 token 发行方**~~（2026-08-11 已消除）。此前用 Base USDC——可升级、
       可暂停、可黑名单的代理，合约地址一旦被拉黑则买票/领奖/提抽成同时失效且无救援。
       **这正是改用链原生币的直接动因**（FR-C-01）：原生币无发行方，没有任何第三方
       能冻结转账。代价是票价随行情浮动，已记为接受项。
       剩余的同类风险只有 treasury 自身拒收（见 FR-C-22），且可由 owner 自救
  - **「只有入口没有出口」的结构性权衡**：资金离开合约原本仅两条路——中奖者 `claim`
    与运营 `withdrawFees`。**2026-08-13 已按 Q9 方案 C 增加第三条：FR-C-29 的
    卡死退款通道**，它不含任何自由裁量权（无权限、无参数选择、金额完全由链上状态决定），
    因此不违反本条禁令（本条禁的是「管理员能动到未领奖金」）

- **FR-C-29** 卡死逃生通道（2026-08-13 增，Q9 方案 C）：某期停在 DRAWING 超过
  `ABANDON_TIMEOUT`（30 天）后，**任何人** **MUST** 可调 `abandonStuckRound(roundId)`
  将其作废；购票者随后用 `refundAbandoned(roundId, rangeIndexes[])` 按 Range 取回票款。
  - 计时锚点 **MUST** 是该期**原定开奖时刻**（`closeTime + SEAL_GAP`），
    **MUST NOT** 用 `drawRequestedAt`——后者会被 `retryDraw` 刷新，
    攻击者每 3 小时重试一次即可无限推迟作废、把逃生通道锁死
  - 退款金额 **MUST** = `票价 × 张数 − 该期抽成`（即不退那 1%）。抽成在购票时已按
    FR-C-20 分账、可能早已提走，退全款会击穿偿付性；按净额退时全部 Range 退完
    恰好等于该期 `pot`，分文不差。每条 Range **MUST** 用与购票时相同的算式重算
  - 非自售部分（注资 / 滚存承接）**MUST** 退回缓冲区，不属于购票者
  - **MUST** 按 Range 而非按地址记账已退款状态，以同时支持分批取回与杜绝重复领取
  - **MUST** 另提供 `refundAbandonedTo(roundId, rangeIndexes[], to)`（2026-08-14
    第 50 轮 A-2 增）：Range 归属恒以 `msg.sender` 为准，`to` 只决定钱付到哪里，
    **不增加任何权限面**；`to` **MUST NOT** 为零地址。
    存在的理由与 `claimTo`（FR-C-17）**完全同源**：本通道晚于 `claimTo` 加入，
    重新引入了 R20 M-1 那一类缺陷 —— 没有 `receive`/`fallback` 的合约钱包买了票、
    该期又卡死作废后，`refundAbandoned` 恒 revert `TransferFailed`。
    而退款**没有** `rolloverExpired` 那样的过期兜底，那笔钱会永久留在该期 `pot` 里，
    成为偿付性台账上一笔永远无法清偿的负债
  - 作废期 **MUST** 惰性化：不可重复作废、不可 `retryDraw`、不可 `claim`
  - 验收：`test/LotteryAbandon.t.sol`（含 fuzz 证明退款总额恒等于自售净额）；
    偿付性不变量 **MUST** 把 ABANDONED 期的 `pot` 计入应付义务，且该分支
    **MUST** 有确定性测试保证被真正走到（fuzz 概率过低，实测长期为 0）

- **FR-C-30** 开奖激励（2026-08-13 增）：`performUpkeep` 的调用者 **MUST** 获得奖励，
  使「需要有人按时按按钮」变成「按了有钱拿」，从而在运营方缺席时仍有人有理由接手。
  - 金额 **MUST** = `该期抽成 × KEEPER_REWARD_BPS`（20%），并依次夹逼：
    ① **上限一张票价**；② **不超过当下实际尚存的 `accruedFees`**（抽成可能已提走，
    不夹会下溢）
  - 资金 **MUST** 只来自抽成，**MUST NOT** 动用奖池（FR-C-20 的分账仍然成立）
  - **MUST** 是常量而非可调参数：多一个可调项就多一个信任面。代价是部署后无法
    适应 gas 与币价的长期变化，只能重新部署——刻意接受
  - **MUST** 按「该期自己的抽成」计算，**MUST NOT** 按历史累计——否则一个 1 张票的
    小期能把之前大期赚的抽成吸走
  - 零票作废（VOIDED）的期 **MUST NOT** 发放奖励——否则无人玩时可每个间隔
    触发一次 VOID 刷钱
  - `retryDraw` **MUST NOT** 发放任何奖励——否则可每 3 小时重试刷钱，
    并顺带烧光运营方的 LINK
  - **MUST** 采用 pull 模式（记账 + `claimKeeperReward`）。当场转账不可行：
    `performUpkeep` 内有 `try this.requestRandomWordsSelf()` 外部自调用，
    直接加 `nonReentrant` 会把自己挡住；而中途向任意调用者转原生币则开了重入口子
  - **MUST** 另提供 `claimKeeperRewardTo(to)`（2026-08-14 第 50 轮 A-3 增）：
    奖励归属恒以 `msg.sender` 为准，`to` 只决定钱付到哪里，**不增加任何权限面**；
    `to` **MUST NOT** 为零地址。理由同 `claimTo`/`refundAbandonedTo`——
    `performUpkeep` 无权限，触发者**常常是合约**（Q8 的 CRE 桥接器就是最典型的一个），
    没有 `receive`/`fallback` 的触发者永远领不走自己的奖励，那笔已从 `s_accruedFees`
    划出的钱就成了 `s_pendingKeeperRewards` 里一笔永远无法清偿的负债
  - **`withdrawFees` MUST 为当期（仍 OPEN 的那一期）预留一份奖励额度**
    （2026-08-14 第 50 轮 A-1 增）。不预留的话，上面夹逼 ② 的
    「不超过当下实际尚存的 `accruedFees`」就变成了一个**人人可拉的断路器**：
    `withdrawFees` 无权限、约 3 万 gas，任何人在封盘期（停售 → 开奖之间、
    抽成不再增加的那 75 分钟）调一次，本期奖励恒为 0 —— 无需抢跑、无需竞速，
    零成本架空本条需求的全部意义。**运营方自己例行提费同样会误伤**，
    这比蓄意骚扰更可能发生。
    - 预留额 = 上面同一套算式（该期抽成 × 20%，夹一次票价上限），**MUST** 与
      发放算式共用同一份实现，两者分叉即意味着预留不足或界面虚报
    - 预留 **MUST NOT** 把提费通道堵死：奖励恒为该期抽成的 20%，故只要有抽成，
      可提额就严格大于 0；零票的期不预留任何东西
    - **MUST** 提供 `withdrawableFees()` 视图，前端 **MUST** 展示它而非裸的
      `s_accruedFees`，否则会对运营方虚报可提金额
  - 未领取的奖励 **MUST** 计入偿付性不变量（`s_pendingKeeperRewards`）
  - **诚实的边界**：一次 `performUpkeep` 约 17.3 万 gas，主网连同 L1 数据费约
    1e-5 ETH。20% 意味着**约 50 张票以上的期才够覆盖 gas**，更小的期无人会来触发。
    奖励创造的是**动机**而非**机制**——冷启动阶段仍需运营方自己触发，
    且它**不替代** `checkUpkeep` 定义的日程，只改变「谁来按按钮」
  - 验收：`test/LotteryKeeperReward.t.sol`（三道闸各一条 + 上限 + 重入 + fuzz 证明奖池不受影响）

### 4.7 事件

- **FR-C-25** 以下事件 **MUST** 齐备，且索引字段足以让前端仅靠事件重建全部历史：
  ```
  RoundOpened(uint32 indexed roundId, uint64 closeTime)
  TicketsBought(uint32 indexed roundId, address indexed buyer, uint32 start, uint32 quantity)
  PotInjected(uint32 indexed roundId, address indexed sender, uint256 amount)
  DrawRequested(uint32 indexed roundId, uint256 indexed requestId)
  DrawSettled(uint32 indexed roundId, uint256 seed, uint32 ticketCount, uint256[] perWinnerAmounts)
  TierConfigSet(uint16[] tierBps, uint8[] winnerCounts)   // 构造时一次性，slot→奖级 映射所需
  CarryReleased(uint32 indexed toRound, uint256 potAmount, uint256 tier1Amount)
  CarryWithheld(uint32 indexed roundId, uint256 amount)
  DrawRequestFailed(uint32 indexed roundId)
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
  - 不同票价量级（1e14 / 1e18 wei）下账目一致
- **FR-T-03** **MUST** 包含 Foundry 不变量测试（`invariant_`），至少覆盖：
  - `合约原生币余额 >= 所有未领奖金 + accruedFees + 滚存缓冲区`（实现收紧为恒等式）
  - `sum(各期 pot) + accruedFees + 已支付总额 == 历史购票总额 + 历史注资总额`
- **FR-T-04** **MUST** 包含以下攻击场景测试：
  - 重入 `claim`（中奖者合约在 `receive` 里回调——原生币下**每次派奖都是一次对
    任意代码的调用**，比 ERC20 时代更危险：ERC20 转账不回调接收方，须构造恶意 token 才能重入）
  - 跨函数重入：派奖回调里横向调用 `performUpkeep` / `buyTickets` / `withdrawFees` /
    `rolloverExpired`
  - 强制打款（`selfdestruct`）不得干扰任何金额计算
  - 旧 VRF 回调覆盖新结果
  - `closeTime` 边界抢跑购票
  - owner 试图把 feeBps 设到上限以上
- **FR-T-05** **MUST NOT** 通过修改测试断言来让实现通过。若测试与规格冲突，
  停下来报告冲突

---

## 6. 前端需求（FR-W）

技术栈：Next.js (App Router) + TypeScript + wagmi v2 + viem + RainbowKit + Tailwind

- **FR-W-01** 首页 **MUST** 展示：当前期号、当前奖池、倒计时、票价、我的持票数
- **FR-W-02** 购票流程为**一步成交**（2026-08-11 随 FR-C-01 改为原生币，
  approve 两步流程已不存在）：直接以 `msg.value = 票价 × 张数` 调 `buyTickets`，
  需有 pending/成功/失败三态。
  - **MUST** 在按钮上显示即将发送的**实际金额**。原生币下同一个输入串的含义比
    稳定币时代大 6 个数量级（"100" 从 100 USDC 变成 100 ETH），不得让钱包弹窗
    成为用户第一次看见数额的地方（2026-08-11 审计 F2，High）
  - **MUST** 拦截余额不足：票款与 gas 出自同一余额，余额恰等于票款也发不出交易
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
- **Q4（票价，2026-08-07；2026-08-11 修订）**：部署默认 1 USDC；
  2026-08-11 改为链原生币计价，默认 `0.0001 ether`（见 FR-C-01 的理由与代价）
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
  测试阶段用自托管轮询 keeper 触发开奖；主网前迁移到 CRE 定时工作流。
  - **CRE 桥接器 MUST 能取回自己名下的开奖奖励**（2026-08-14 第 50 轮 A-3）：
    CRE 的写入只能投递到实现 `IReceiver` 的合约，因此转调 `performUpkeep` 的
    `msg.sender` 是 `LotteryKeeperReceiver` 本身，FR-C-30 的奖励记在**它**名下。
    初版桥接器既没有领取路径、也没有 `receive` —— 每一期最多一张票价的运营抽成
    被永久烧进一个取不出的余额。桥接器 **MUST** 提供 `receive()` 与一个
    **无权限、无自由裁量**的 `sweepKeeperReward()`：金额与去向完全由链上状态决定，
    去向是构造时钉死的 `i_rewardBeneficiary`（**MUST NOT** 有 setter，
    否则本合约「没有可被滥用的杠杆」这个前提就没了）
- **Q9（VRF 换源杠杆的根因修复，2026-08-11 提出；2026-08-13 已决：采纳 B + C）**：
  见 FR-C-22 的订正说明——`setCoordinator` 的修饰符是 `onlyOwnerOrCoordinator`，
  官方订阅迁移与 owner 私钥失窃两条路径都能造成**不可恢复的全局冻结**。
  纪律层缓解（多签、不调 migrate）已写入 FR-C-22，但**不能应对 Chainlink 强制迁移**。
  三个候选方案，需要拍板：
  - **A（已执行）** 仅纪律：写进信任方清单 + 订阅所有者用多签。零代码，
    但把「Chainlink 何时淘汰 v2.5」变成了项目的生存时限
  - **B（推荐评估）** 把 owner 移交给一个极小的、不可升级的 `LotteryAdmin`，
    它**只**转发 setTreasury / setFeeBps / setSalesPaused，不含任何通用
    `execute(address,bytes)`、也不含 `transferOwnership`。此后 `setCoordinator`
    只剩 coordinator 自己能调（= 只有合法迁移），于是可以让 `_requestRandomWords`
    改用 `s_vrfCoordinator`（跟随迁移）并去掉 `CoordinatorTampered` 校验。
    一次解决 H-1 与 M-2，不引入代理、不引入行政提款，符合 FR-C-24 的立意。
    **代价必须说清**：owner 权限从此永久绑定在那个合约上，`LotteryAdmin` 若有 bug，
    三项业务权限一起失去（但奖池不受影响——它们本来就动不了奖池）
  - **C（独立议题）** 兜底逃生通道：`abandonStuckRound(roundId)`——某期在 DRAWING
    停留超过长阈值（如 30 天）后，任何人可标记为可退款，购票者按「票价 × 张数」
    pull 式原路取回，carry 退回缓冲。**不含任何自由裁量权**，因此不违反 FR-C-24
    （该条禁的是「管理员能动到未领奖金」）。还需一条配套的缓冲区逃生规则，
    否则 `s_pendingPot` / `s_pendingTier1` 在同一场景下仍然出不来。
    这正是 FR-C-24 自己点出的「主网前应当评估」的那条

  **已决（2026-08-13）：采纳 B + C。**
  - B 落地为 `src/LotteryAdmin.sol` + Lottery 移除钉死（见 FR-C-22 订正）
  - C 落地为 FR-C-29
  - 选择理由：本项目的核心卖点是 FR-C-24「不存在任何能挪用奖池的管理员函数」，
    留一个「运营方可暗中赢走头奖」的杠杆与之矛盾——冻结是可见且自伤的，
    暗中操纵开奖是不可见的偷窃，性质不同。C 则是唯一**不依赖我们把失效模式列全**的保护。
