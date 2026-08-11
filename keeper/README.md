# 自托管 keeper

Chainlink Automation 已于 2026 年中弃用，替代品 CRE 的部署权限还没批下来
（见 `keeper-cre/`）。这个目录是过渡方案：一个每分钟跑一次的 Windows 计划任务。

## 它做两件事

| 动作 | 触发条件 | 合约函数 |
|---|---|---|
| 到点开奖 | `checkUpkeep` 返回 true | `performUpkeep` |
| 卡住兜底 | 有期停在 DRAWING 超过 `DRAW_TIMEOUT`(3h) | `retryDraw` |

两个都是**无权限函数，任何人可调**。keeper 不在信任边界内——它只是"有人按时来按按钮"，
按不按都不影响资金安全，最坏是开奖延迟。

## 安装

```powershell
powershell -ExecutionPolicy Bypass -File keeper\install-task.ps1
```

不需要管理员权限。装完立即生效，日志写在 `keeper/keeper.log`（已 gitignore）。

```powershell
Get-ScheduledTask -TaskName LuckYou-Keeper          # 看状态
Get-ScheduledTaskInfo -TaskName LuckYou-Keeper      # 看上次运行结果
Start-ScheduledTask -TaskName LuckYou-Keeper        # 立即跑一次
powershell -ExecutionPolicy Bypass -File keeper\uninstall-task.ps1   # 卸载
```

手动排查时可以带 `-Force` 跳过节流，强制执行卡住期扫描：

```powershell
powershell -ExecutionPolicy Bypass -File keeper\keeper.ps1 -Force
```

## 为什么要经 `run-hidden.vbs` 启动（别改回直接跑 powershell）

`powershell.exe` 是**控制台程序**。计划任务在交互会话里启动它时，Windows 会
**先创建控制台窗口**，`-WindowStyle Hidden` 是在那之后才生效的——于是每分钟闪一次黑框。

更麻烦的是那个窗口会**抢焦点**：按 Win 弹出的开始菜单会被下一次触发关掉，
用起来就像 Win 键失灵了（2026-08-11 实测踩过，不是理论问题）。

两条解法：

| 方案 | 是否需要管理员 | 本项目采用 |
|---|---|---|
| 任务设成 S4U 登录类型（不在交互会话运行） | **需要** | ✗ 注册时 Access denied |
| 经 `wscript.exe` 启动（GUI 子系统，自身不建控制台） | 不需要 | ✓ |

`run-hidden.vbs` 用 `Run(cmd, 0, True)` 以 `SW_HIDE` 拉起 PowerShell，
第三个参数 `True` 表示等待结束，好让计划任务的 `MultipleInstances` 与超时设置按预期生效。

**如果哪天又开始闪窗口**，八成是有人把任务的 Execute 改回了 `powershell.exe`。
核对方法：

```powershell
(Get-ScheduledTask -TaskName LuckYou-Keeper).Actions[0].Execute   # 应为 wscript.exe
```

## 请单独给它一个账户

脚本优先读 `contracts/.env` 里的 `KEEPER_PRIVATE_KEY`，找不到才回退到部署者的
`PRIVATE_KEY`，并**每次都在日志里告警**。

原因：`cast` 只接受 `--private-key`，密钥会出现在本机进程命令行里。keeper 既然
一个特权都不需要，就不该拿着 owner 的钥匙——否则本机一旦被入侵，连带丢掉
`setTreasury` / `setFeeBps` / `setSalesPaused` 和合约所有权。

```bash
# 在 contracts/.env 里加一行（该文件已 gitignore）
KEEPER_PRIVATE_KEY=0x...   # 一个只放少量测试网 ETH、专用于付 gas 的账户
```

## 为什么是每分钟

合约按**售票窗口完整度**等比例释放滚存缓冲（FR-C-27/28）：keeper 越及时，
本期能释放的额度越高。快节奏测试实例的名义窗口只有 45 分钟：

| keeper 延迟 | 本期可释放的缓冲比例 |
|---|---|
| 准时 | 100% |
| 晚 1 分钟 | ~97.8% |
| 晚 5 分钟 | ~88.9% |
| 晚 15 分钟 | ~66.7% |

每分钟一次的开销可忽略：绝大多数轮次只发一次只读 `checkUpkeep`；卡住期扫描
每 10 分钟才做一次。

## 已知限制

- **只在这台机器开着时运行。** 关机或休眠期间不开奖；开机后计划任务的
  `StartWhenAvailable` 会补跑一次，错过的场次由合约自己跳过（Q2 的日程语义，
  不产生累积漂移），但那几期的缓冲释放比例会偏低。
- **单点。** 正式运营应换成 CRE 或多节点冗余。好在这不影响资金安全：
  keeper 全停也只是开奖延迟，任何人（包括前端上的「🎰 触发开奖」按钮）都能顶上。
- **公共 RPC 会限流。** 偶发的读取失败会记 `WARN` 并在下一分钟自然重试，
  不需要人工介入。
