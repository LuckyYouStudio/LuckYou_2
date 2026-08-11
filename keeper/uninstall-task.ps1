# 移除 LuckYou keeper 计划任务
$ErrorActionPreference = 'Stop'

$taskName = 'LuckYou-Keeper'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -eq $existing) {
    Write-Host "计划任务 $taskName 不存在，无需移除"
}
else {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "已移除计划任务：$taskName"
}
Write-Host "（日志文件 keeper/keeper.log 保留，如不需要请自行删除）"
