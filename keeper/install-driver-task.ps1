# 注册（或更新）多期验证驱动器的计划任务，每 2 分钟跑一次。
#
# 2 分钟是权衡：开奖迟到到跨过下一个场次的售票窗口就会「跳场次」（拉长验证周期），
# 而每次 tick 只有三次只读 RPC，成本可以忽略。
#
# 必须经 wscript.exe 启动，不能直接 Execute powershell.exe —— 见 run-driver-hidden.vbs
# 顶部的说明（黑框抢焦点，Win 键失灵）。
#
# 路径一律用 Join-Path 拼，本文件里不写字面反斜杠：见 CLAUDE.md 里
# 「生成 Windows 脚本时不要写字面反斜杠」那条。

$taskName = 'LuckYou 多期验证驱动器'
$launcher = Join-Path $PSScriptRoot 'run-driver-hidden.vbs'
if (-not (Test-Path $launcher)) { throw "找不到启动器：$launcher" }

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $launcher)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 2)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host '已移除旧任务'
}
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Description '多期验证：到点开奖 + 补买票。仅 Base Sepolia。' | Out-Null

$logPath = Join-Path $PSScriptRoot 'validation-driver.log'
Write-Host "已注册：$taskName（每 2 分钟）"
Write-Host "查看日志：   Get-Content $logPath -Tail 20"
Write-Host "立即跑一次： Start-ScheduledTask -TaskName '$taskName'"
Write-Host "停止：       Unregister-ScheduledTask -TaskName '$taskName' -Confirm:0"
