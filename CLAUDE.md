# CLAUDE.md

> 本文件是本仓库的常驻上下文。开始任何任务前先读 `docs/SPEC.md`。

## 项目

链上周期开奖彩票。Foundry 合约 + Next.js 前端。目标链 Base Sepolia → Base。
测试网先行完整验证；是否上主网取决于合规评估（牌照/运营主体）。
代码质量按生产标准写。

## 目录结构

```
contracts/          Foundry 项目
  src/              合约
  test/             测试（与 src 同名，后缀 .t.sol）
  script/           部署与交互脚本
web/                Next.js 前端
docs/SPEC.md        需求规格（唯一事实来源）
```

## 常用命令

```bash
# 合约
cd contracts
forge build
forge test -vv                    # 改完代码必跑
forge test --match-test <name> -vvvv
forge coverage
forge fmt                         # 提交前必跑
forge snapshot                    # gas 基准

# 前端
cd web
pnpm dev
pnpm typecheck                    # 改完必跑
pnpm lint
```

## 硬性规则

1. **每次改完合约代码，必须跑 `forge test` 并报告结果。** 不要说「应该能通过」。
2. **测试失败时，先假设是实现错了，不是测试错了。** 绝对不允许为了让测试变绿而
   修改断言、删测试、或加 `vm.skip`。如果确信规格本身有矛盾，停下来说明，不要
   自己拍板改规格。
3. **不引入 SPEC 里没写的依赖。** 需要新库先问。
4. **不加 SPEC 第 1.2 节明确排除的功能。** 特别是：不要"顺手"加可升级代理、
   不要加 `emergencyWithdraw`、不要加代币激励。
5. **不要为了通过而降低要求。** 覆盖率不够就补测试，不要改阈值。
6. **遇到 SPEC 第 9 节的未决问题，停下来问，不要自己选一个继续。**

## Solidity 规范

- pragma 固定版本 `0.8.26`，不用 `^`
- 命名：storage 变量 `s_` 前缀，immutable `i_` 前缀，constant 全大写
- **一律用 custom error，不用 `require` 字符串**
- 外部函数排序：external → public → internal → private，view/pure 放各组末尾
- 所有 external/public 函数必须有 NatSpec（`@notice` 至少要有）
- 状态变更必须 emit 事件
- 转账一律 CEI 顺序；原生币出账用 `call{value:}` 并检查返回值，禁用 `transfer`/`send`
- 用命名 mapping 参数：`mapping(uint32 roundId => Round)`

## 测试规范

- 测试命名：`test_<行为>`、`test_RevertWhen_<条件>`、`testFuzz_<性质>`、
  `invariant_<不变量>`
- 每个 revert 分支都要有对应的 `test_RevertWhen_`，且用
  `vm.expectRevert(Contract.ErrorName.selector)` 而非无参数版本
- 用 `makeAddr()` 生成测试地址，不要硬编码 `address(1)`
- 复杂 setup 抽成 helper，但 helper 里不要藏断言

## 前端规范

- 严格 TypeScript，`any` 需要注释说明理由
- 合约交互统一走 `web/src/lib/contracts.ts` 导出的配置，不在组件里写地址
- 所有链上写操作要有 pending / success / error 三态 UI
- 不用 localStorage 存业务数据，状态从链上读

## 工作方式

- **动手前先给计划。** 涉及多个文件的任务，先列出要改哪些文件、每个文件改什么，
  等我确认再写。
- 一次只做一个里程碑内的一个模块，不要一口气写完整个项目。
- 每完成一个可验证的单元就停下来报告，让我确认后再继续。
- 提交信息用中文，格式 `<类型>: <描述>`，类型限 feat/fix/test/refactor/docs/chore。

## 已知陷阱（踩过的坑，别重复）

- Chainlink 的 mock 会 import 带版本号的 OpenZeppelin 路径
  （`@openzeppelin/contracts@4.9.6/`），`foundry.toml` 的 remappings 必须显式
  加这一条，否则编译报 "Source not found"
- `VRFConsumerBaseV2Plus` 已经声明了 `error ZeroAddress()`，子合约重复声明会
  编译失败
- VRF 回调有 gas 上限，回调里做循环或转账会静默失败，整期卡在 DRAWING
- `forge build` 默认会去 binaries.soliditylang.org 下载 solc，网络受限时用
  `--use <本地 solc 路径>`
- Windows PowerShell 5.1 读 `.ps1` 时按系统 ANSI 码页解析，**无 BOM 的 UTF-8
  中文注释会被拆坏**，连带把字符串终止符吃掉、报一堆莫名其妙的语法错误。
  写 `.ps1` 一律存成 **UTF-8 with BOM**
- Windows 计划任务里**不要直接 Execute `powershell.exe`**：它是控制台程序，
  交互会话下 Windows 会先建控制台窗口，`-WindowStyle Hidden` 在那之后才生效，
  结果每次触发闪一次黑框**并抢焦点**（表现为「Win 键失灵」——开始菜单被下次触发关掉）。
  S4U 登录类型能根治但要管理员权限；无提权的做法是经 `wscript.exe` 启动一个
  `Run(cmd, 0, True)` 的 .vbs（GUI 子系统，自身不建控制台）
- **PowerShell 5.1 里 `$ErrorActionPreference='Stop'` + 原生命令 `2>&1` = 定时炸弹**
  （2026-08-15 实测，驱动器连抛 1.5 小时才被发现）。重定向会把 stderr 每行包成
  ErrorRecord（NativeCommandError）并**升级为终止性错误**，于是
  「先跑再查 `$LASTEXITCODE` 决定怎么办」这套写法**根本执行不到**——直接跳去 catch，
  **把整个 try 块剩下的步骤全部中断**。
  最阴的是它只在原生命令失败时才发作：`cast call` 一路成功时毫无征兆，
  等到某次正常 revert（`NothingToClaim` 这种预期内的失败）才炸，
  而那时你已经默认这段代码是好的了。
  解法是在重定向期间临时把 EAP 降为 `Continue`，既留住 stderr 文本用于记日志，
  又让退出码回到「可判断」而不是「已爆炸」：
  ```powershell
  $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = & $exe @args 2>&1 | ForEach-Object { "$_" }
        return @{ ok = ($LASTEXITCODE -eq 0); out = ($out -join "`n") } }
  finally { $ErrorActionPreference = $saved }
  ```

- **生成 Windows 脚本时，内容里不要写字面反斜杠**（2026-08-15 踩到）。
  经 heredoc/python 这条链路写文件，双反斜杠会被折叠，于是本该是路径分隔符的
  `\` + `v` 变成**真的垂直制表符 0x0B**，文件在那里被无声截断。
  症状极具欺骗性：vbs 构造出半截命令行，powershell 根本没跑，
  **而计划任务照常返回 LastTaskResult = 0**——「成功但什么都没做」。
  正确做法是让生成内容里根本不出现反斜杠：VBScript 用 `fso.BuildPath` + `Chr(34)`，
  PowerShell 用 `Join-Path`，Python 侧用 `chr(92)`。
  另注：**用 `splitlines()` 查这类损坏会假阴性**——垂直制表符本身就被当成换行，
  受损行被切成两半，看起来「没有控制字符」。要按 `ord(c) < 32` 逐字符扫原文。

- **slither 报「本机装不了 solc」多半是假的**：它需要一个独立的 solc 可执行文件
  （foundry 内置的那份它调不到），但本机 `solc-select` 早已安装，只是**没选版本**。
  两条命令解决，且**必须装 0.8.26**——项目 pragma 是固定版本不带 `^`，
  装成默认的 0.8.36 会直接编译不过：
  ```bash
  export PATH="$HOME/AppData/Local/Programs/Python/Python312/Scripts:$PATH"
  solc-select install 0.8.26 && solc-select use 0.8.26
  slither .    # 记得从 contracts/ 跑，且 foundry 也要在 PATH 上
  ```
  另注：`slither . --filter-paths "lib/|test/"` 用正斜杠在 Windows 上**不生效**，
  会假报 `0 result(s) found`。核对时必须不带过滤跑一遍，再自行按路径筛。
