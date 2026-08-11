# LuckYou · 链上周期开奖彩票

抽签制周期彩票：按双色球日程（每周二/四/日，北京时间 20:00 停售、21:15 开奖）售票，
Chainlink VRF v2.5 提供随机数，Chainlink Automation 触发开奖。目标链 Base Sepolia → Base。

> 需求唯一事实来源：[docs/SPEC.md](docs/SPEC.md)（v1.1，所有已拍板决策见第 9 节）

## 架构

```
┌─────────────┐   viem/事件    ┌──────────────────┐
│  Next.js    │ ─────────────► │  Lottery.sol     │
│  web/       │ ◄───────────── │  (Base)          │
└─────────────┘  读事件/状态   └──────────────────┘
                                   ▲          ▲
                          VRF v2.5 │          │ Automation
                                   │          │
                            ┌──────┴──────────┴──────┐
                            │   Chainlink 网络       │
                            └────────────────────────┘
```

## 核心设计

- **抽签制**：从已售票中抽取中奖票（等价于全员机选、期期必开），非双色球式选号匹配
- **Range 压缩存储**：一次购买只写一条 `[start, end)` 区间，二分反查持有人（FR-C-04/05）
- **双色球日程**：锚定固定场次（间隔循环 [2d,3d,2d]），封盘期 75 分钟，错过场次自动跳过
- **奖级** 60% / 25%（2 名）/ 15%（5 名）；票数不足的奖级不开出，奖金滚入下期一等奖份额
- **原生币计价**：票价 0.0001 ETH，买票一步成交无需授权；避开稳定币发行方的暂停/黑名单风险（FR-C-01）
- **资金隔离**：奖池与 1% 运营抽成自购票起分账；费率硬上限 10%；
  **不存在任何能挪用奖池的管理员函数**；过期未领奖金滚回奖池
- **VRF 安全**：回调只记账不转账；超时任何人可重试；旧回调无法覆盖新结果

## 本地跑起来

```bash
# 1. 启动本地链
anvil

# 2. 部署（另开终端；先挖 2 个空块规避 VRF mock 在 block 0 的下溢）
cast rpc evm_mine --rpc-url http://127.0.0.1:8545
cast rpc evm_mine --rpc-url http://127.0.0.1:8545
cd contracts
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 3. 前端测试台
cd ../web
npm install
npm run sync-abi
npm run dev        # http://localhost:3000
```

测试台提供：一步购票（原生 ETH，无需授权）、奖池注资、时间快进、模拟 keeper 开奖与 VRF 回调、
一键领奖、运营面板；`/history` 页从链上事件重建个人购票与领奖记录（无后端）。

## 测试

```bash
cd contracts
forge test           # 111 个测试：单元 + fuzz + 不变量 + 攻击场景
forge coverage       # Lottery.sol 行覆盖 99.26%，分支 90.74%
forge snapshot       # gas 基准
```

不变量（Handler 有界随机调用）：

- 偿付恒等式：`合约余额 == 未领奖金 + 进行中奖池 + 滚存 + accruedFees`（严格相等，零泄漏）
- 资金守恒：`购票 + 注资 == 在库 + 已派奖 + 已提费`
- 攻击场景：恶意 ERC20 重入 claim 被拦截、closeTime 边界抢跑、owner 费率越权

## 部署到 Base Sepolia

```bash
cd contracts
cp .env.example .env    # 填入 PRIVATE_KEY、RPC、VRF_SUBSCRIPTION_ID、TREASURY_ADDRESS
forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY --broadcast --verify
```

部署脚本会打印待办清单：到 [vrf.chain.link](https://vrf.chain.link) 给订阅加 consumer 并充 LINK。
开奖触发（keeper）：Chainlink Automation 已于 2026 年中弃用（替代品为 CRE），
测试阶段用自托管轮询 keeper（每分钟 `checkUpkeep`，为真则 `performUpkeep`），
主网前迁移到 CRE 定时工作流。keeper 不在信任边界内，任何人可触发开奖与重试。
链上参数（VRF coordinator / keyHash）已按 chainid 写入脚本，
来源：[Chainlink VRF v2.5 支持网络](https://docs.chain.link/vrf/v2-5/supported-networks)。

测试网手动运维：`script/Interact.s.sol`（status / buy / poke / retry / claimAll / rollover）。

## Gas 基准（forge snapshot）

| 函数 | 平均 | 说明 |
|---|---|---|
| buyTickets | ~78k | 与张数基本无关（Range 压缩），首次购买含冷存储另计 |
| claim | ~51k | 单奖级、含原生币转账 |
| injectPot | ~55k | |
| VRF 回调结算 | ~203k | 含 8 个中奖 slot 派生与事件（预算 1M，余量充足） |
| 部署 | 3.74M / 19.99KB | 低于 24KB 限制 |

优化分析结论（未改动）：三个最贵路径分别受制于事件字段（FR-C-25 固定签名要求回调内派生中奖人）、
每次购买新增一条 Range 的冷存储、以及视图辅助函数带来的部署体积——三者都是规格要求或测试台
便利性的直接代价，当前量级下无优化必要。

## 已知限制

- **前端为本地测试台形态**：使用 anvil 解锁账户，无需浏览器钱包；接入 MetaMask/RainbowKit
  需注册 WalletConnect projectId 后在 `web/src/lib/contracts.ts` 基础上扩展 connector
- **Base Sepolia 实际部署**需要持有测试币的私钥与 VRF 订阅（人工步骤，见上）
- **合规**：以真实资金运营彩票在绝大多数司法辖区属受监管的博彩业务（在中国境内属违法）。
  本项目定位为测试网验证；是否上主网取决于牌照与运营主体的合规评估（SPEC 第 9 节 Q7）
