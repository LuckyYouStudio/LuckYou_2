# Claude Code 提示词（按阶段执行）

## 用法

1. 先把 `SPEC.md` 放到 `docs/SPEC.md`，`CLAUDE.md` 放到仓库根目录
2. 按顺序执行下面的 Prompt，**一个做完确认无误再做下一个**
3. 遇到它跑偏，用文末的「纠偏话术」

---

## P0 · 初始化

```
读 docs/SPEC.md 和 CLAUDE.md。

初始化仓库骨架：
- contracts/ 用 forge init 初始化，删掉默认的 Counter 相关文件
- 安装 @chainlink/contracts 和 OpenZeppelin，配好 foundry.toml 的 remappings
  （注意 CLAUDE.md「已知陷阱」里 OpenZeppelin 带版本号路径那条）
- 建 .env.example，列出需要的环境变量，不要填真实值
- .gitignore 要覆盖 .env、out/、cache/、node_modules/、broadcast/

不要写任何业务合约。做完跑一次 forge build 确认能编译，然后停下来告诉我结果。
```

---

## P1 · 合约核心（M1）

> 拆成三步，不要一次让它写完整个合约。

### P1.1 数据结构与购票

```
实现 SPEC 的 FR-C-01 到 FR-C-07（计价、票务、Range 存储、二分查找）。

先只写这部分：
- Round 结构体、TicketRange 结构体、状态枚举
- 构造函数（注入 token、票价、日程锚点时间戳与间隔循环数组、treasury、
  feeBps、各奖级比例）
- buyTickets：写入一条 Range，SafeERC20 收款，分账到 pot 和 accruedFees
- ownerOfTicket(roundId, ticketId)：二分查找

先不要写开奖、VRF、claim。

写完后同步写这部分的测试，至少包含：
- 购票记账正确（pot 和 fee 分开）
- buyTickets(100) 的 gas < buyTickets(10) 的 3 倍（用 gasleft() 测量并断言）
- testFuzz：二分查找结果 == 线性扫描结果

跑 forge test，把结果贴给我。
```

### P1.2 状态机与开奖

```
在现有基础上实现 FR-C-08 到 FR-C-16（状态机、VRF、多奖级、retryDraw）。

特别注意这三条，它们是这个合约最容易写错的地方：
- FR-C-10：发起 VRF 请求后立刻开下一期，不等回调
- FR-C-15：fulfillRandomWords 里 state != DRAWING 时静默 return
- FR-C-16：回调里只记账，不转账、不循环

FR-C-12 的多奖级派生允许同票号中多个奖级，这是刻意的，不要试图去重规避。

SPEC 第 9 节 Q1 已拍板：票数少于某奖级名额时该奖级不开出，奖金滚入下期并
计入下期一等奖份额（双色球逻辑）。按 SPEC 第 9 节的验收条件实现，不是 TODO。

closeTime/drawTime 的推进按 SPEC 第 9 节 Q2 的双色球日程实现：每周二/四/日，
20:00 停售、21:15 开奖（SEAL_GAP 75 分钟），场次间隔循环 [2, 3, 2] 天，
新期取日程中晚于当前时刻的最近场次。测试要覆盖「跨场次极端延迟跳过」的情况。

测试至少覆盖：完整生命周期、空期作废（不消耗 VRF）、下一期立即开售、
retryDraw 超时前后、以及旧 VRF 回调不能覆盖新结果。

跑 forge test，贴结果。
```

### P1.3 领奖与权限

```
实现 FR-C-17 到 FR-C-26（claim、滚存、注资 injectPot、分账、权限边界、事件）。

重点：
- FR-C-23：暂停售票不能影响 claim，要有测试证明暂停状态下中奖者仍能领奖
- FR-C-24：不允许存在任何能动到未领奖金的管理员函数，一个都不要加
- FR-C-25：事件字段要足够前端仅靠事件重建全部历史，写之前先把事件列表贴给我确认

跑 forge test 和 forge coverage，贴结果。
```

---

## P2 · 测试加固（M2）

```
按 SPEC 第 5 节补齐测试到达标：

1. 不变量测试（FR-T-03）——建一个 Handler 合约做有界随机调用，
   两条不变量：偿付能力、资金守恒
2. 攻击场景（FR-T-04）——重入用一个带 transfer 回调的恶意 ERC20 来测
3. 双精度测试（FR-T-02）——6 decimals 和 18 decimals 各跑一遍全套

跑 forge coverage，如果没到 90% 就补测试，不要改阈值。
把未覆盖的行列给我看。
```

---

## P3 · 部署（M3）

```
实现 SPEC 第 7 节（FR-D-01 到 FR-D-04）。

Deploy.s.sol 按 chainid 分支配置 Base Sepolia 和 Base 主网的 VRF coordinator
和 keyHash——这两个值你要联网查 Chainlink 官方文档确认，不要凭记忆填。
查到后把来源链接贴给我。

Interact.s.sol 提供：查当前期状态、购票、（本地）快进时间触发开奖。

不要执行任何真实部署，只写脚本。
```

---

## P4 · 前端（M4）

> 同样拆开，别让它一次生成整个 app。

### P4.1 基建

```
在 web/ 初始化 Next.js（App Router）+ TypeScript + Tailwind + wagmi v2 +
viem + RainbowKit，配置 Base Sepolia。

建 src/lib/contracts.ts 统一导出合约地址和 ABI（ABI 从 contracts/out 读，
写个脚本同步，不要手抄）。

只做到「连上钱包能显示地址和链」为止，跑 pnpm dev 确认，然后停。
```

### P4.2 主界面

```
实现 FR-W-01、FR-W-02、FR-W-05、FR-W-06。

FR-W-02 的 ERC20 两步授权是重点：allowance 检查 → approve → buyTickets，
两笔交易各自独立的 pending/success/error 状态，不要合并成一个 loading。

FR-W-06 的「已截止但未开奖」中间态别忘了，很多人会漏，结果倒计时卡在 00:00。

跑 pnpm typecheck。
```

### P4.3 历史与领奖

```
实现 FR-W-03、FR-W-04。

历史数据只能从合约事件读（FR-W-03 明确禁止后端）。用 viem 的 getLogs，
注意 RPC 对区块范围的限制，需要分段查询。

中奖未领取时要在首页显著提示，不能只放在历史页里。
```

---

## P5 · 收尾（M5）

```
1. forge fmt + pnpm lint 全过
2. 补全所有 external/public 函数的 NatSpec
3. forge snapshot 出 gas 基准，找出最贵的三个函数，分析是否有优化空间，
   先给分析结论，不要直接改
4. 写 README：架构图、本地跑起来的步骤、部署步骤、已知限制
```

---

## 纠偏话术

遇到常见跑偏，直接粘这些：

| 情况 | 话术 |
|---|---|
| 它改测试来让测试通过 | `你修改了测试断言。按 CLAUDE.md 规则 2，测试失败时先假设是实现错了。把断言改回去，修实现。` |
| 它一口气写太多 | `停。你一次改了太多文件。回滚到上一个可验证状态，我们一次只做一个模块。` |
| 它自己决定了未决问题 | `SPEC 第 9 节 Q<n> 是未决问题，你自行选了一个方案。说明你选它的理由和另外两个方案的代价，我来定。` |
| 它加了没要求的功能 | `你加了 SPEC 里没有的 <X>。按 1.2 节这属于非目标，删掉。` |
| 它说"应该可以工作" | `跑一遍 forge test 把实际输出贴给我。不要推测。` |
| 它凭记忆填链上地址 | `这些地址联网到 Chainlink 官方文档核实，把来源链接贴出来。` |
| 覆盖率不达标它想降阈值 | `不要动阈值，补测试。先把未覆盖的行列出来。` |

---

## 几条实战建议

- **每个 P 开始前 `/clear`。** 上下文里堆着上一阶段的细节会让它把已经定好的
  东西又改一遍。CLAUDE.md 和 SPEC.md 会自动重新加载，不会丢。
- **用 plan mode（Shift+Tab）跑 P1.2 和 P2。** 这两步涉及最多设计判断，
  先看它的计划比事后 review 代码便宜。
- **每个阶段结束就 commit。** 它偶尔会大范围重构，有 commit 才能干脆地回滚。
- **让它先写测试再写实现，效果比反过来好。** 想试的话，把 P1.x 的顺序改成
  「先写测试并确认全部失败，再写实现让它们通过」。
