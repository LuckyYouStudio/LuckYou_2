# 注册（或更新）Windows 计划任务，每分钟跑一次 keeper.ps1
#
# 为什么是每分钟：合约按「售票窗口完整度」等比例释放滚存缓冲——keeper 越及时，
# 本期能释放的额度越高。快节奏测试实例的名义窗口只有 45 分钟，晚 1 分钟约损失
# 2% 释放额，晚 5 分钟约损失 11%。每分钟一次的 RPC 开销可忽略（多数轮次只有 1 次只读调用）。
#
# 用法（普通用户权限即可，不需要管理员）：
#   powershell -ExecutionPolicy Bypass -File keeper\install-task.ps1

$ErrorActionPreference = 'Stop'

$taskName = 'LuckYou-Keeper'
$script = Join-Path $PSScriptRoot 'keeper.ps1'

if (-not (Test-Path $script)) { throw "找不到 $script" }

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`"" `
    -WorkingDirectory $PSScriptRoot

# 立即开始，每 1 分钟重复一次，无限期
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "已移除旧任务，准备重新注册"
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Description 'LuckYou 彩票 keeper：到点触发开奖、VRF 超时重试' | Out-Null

Write-Host "已注册计划任务：$taskName（每分钟一次）"
Write-Host "日志：$(Join-Path $PSScriptRoot 'keeper.log')"
Write-Host ""
Write-Host "查看状态： Get-ScheduledTask -TaskName $taskName"
Write-Host "立即跑一次： Start-ScheduledTask -TaskName $taskName"
Write-Host "卸载：       powershell -ExecutionPolicy Bypass -File keeper\uninstall-task.ps1"
