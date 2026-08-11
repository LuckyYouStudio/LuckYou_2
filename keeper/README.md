# 自托管 keeper

Chainlink Automation 已于 2026 年中弃用，替代品 CRE 的部署权限还没批下来
（见 `keeper-cre/`）。这个目录是过渡方案。

## 当前运维模式：手动保底（2026-08-11 起）

**计划任务默认不安装。** 现阶段开奖靠人工兜底，正式上线前再换成正规的服务调用。
这样机器上不需要常驻任何签名密钥。

日常只有两步：

```powershell
# 1. 查一眼现在该不该开奖（**只读，不需要任何密钥**）
powershell -ExecutionPolicy Bypass -File keeper\keeper.ps1 -CheckOnly
```

2. 若显示「开奖已到期」，打开测试站点点 **🎰 触发开奖** ——
   走你自己的钱包签名，机器上不留私钥。任何人都能点，keeper 不在信任边界内。

`-CheckOnly` 同时会报告有没有期卡在 DRAWING 超过 3 小时（那种情况需要有人调
`retryDraw`，前端也有对应按钮）。

> 为什么不图省事一直挂着计划任务：见下方「请单独给它一个账户」。
> 无人值守 = 机器上必须常驻一把能发交易的钥匙，而手动模式一把都不需要。

## 想自动化时（可选）

下面这套仍然可用，装之前**先按后文配好 keeper 专用密钥**——脚本是失败关闭的，
没配密钥会直接拒绝运行，不会退回用你的部署者私钥。

## 它做两件事

| 动作 | 触发条件 | 合约函数 |
|---|---|---|
| 到点开奖 | `checkUpkeep` 返回 true | `performUpkeep` |
| 卡住兜底 | 有期停在 DRAWING 超过 `DRAW_TIMEOUT`(3h) | `retryDraw` |

带 `-CheckOnly` 时两件都只报告、不发交易，因此不需要签名密钥。

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

**脚本是失败关闭的：找不到 keeper 专用密钥就记 ERROR 退出，绝不回退到部署者
`PRIVATE_KEY`。**

此前的实现是「找不到就回退、只记一行 WARN 然后继续」——2026-08-11 的 R21 审计
指出并实测确认：那让一个每分钟触发的无人值守桌面任务连续 44 次经手了合约 owner
的私钥。keeper 一个特权都不需要（`performUpkeep`/`retryDraw` 任何人可调），
停摆只是开奖延迟、任何人都能顶上；而 owner 私钥泄露不可逆，还会直接坐实
SPEC Q9 里那条不可恢复的全局冻结。**宁可停，绝不回退。**

### 推荐：用 keystore，密钥不进进程命令行

（此前这份 README 声称「`cast` 只接受 `--private-key`」——**那是错的**。
实测 `cast send --help`：`--keystore` / `--account` / `--password-file` 都支持。）

```bash
# 把 keeper 专用私钥导入 foundry keystore（会提示设置密码）
cast wallet import luckyou-keeper --interactive
```

再把密码写进一个只有你能读的文件，**放在仓库外**（别放进 `keeper/`，见下方目录权限），
然后在 `contracts/.env` 里：

```bash
KEEPER_ACCOUNT=luckyou-keeper
KEEPER_PASSWORD_FILE=C:\Users\<你>\.luckyou\keeper.pwd
```

### 退而求其次：原始私钥

```bash
KEEPER_PRIVATE_KEY=0x...   # 只放少量测试网 ETH、专用于付 gas 的账户
```

这条路脚本仍然支持，但每次都会告警——密钥会出现在本机进程命令行里，
任何本地进程都能看到。

### ⚠️ 目录权限

`keeper/` 继承了 `C:\` 的 ACE，`NT AUTHORITY\Authenticated Users` 有 **Modify**
权限（`icacls keeper` 可自查）。也就是说这台机器上任何已认证用户都能改写
`keeper.ps1`，而它每分钟带着签名密钥运行一次。

多用户机器上**必须**收紧：

```powershell
icacls "C:\test\LuckYou_2\keeper" /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" /grant:r "SYSTEM:(OI)(CI)F"
```

密码文件同理，且**不要**放在这个目录里。

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
