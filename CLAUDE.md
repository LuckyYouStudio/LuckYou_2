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
