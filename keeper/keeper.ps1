# LuckYou 自托管 keeper —— 单次巡检（由 Windows 计划任务反复调用）
#
# 职责（都是合约里**无权限**的函数，任何人可调）：
#   1. checkUpkeep 为真 → performUpkeep：到点开奖并开出下一期
#   2. 有期卡在 DRAWING 且超过 DRAW_TIMEOUT(3h) → retryDraw：VRF 掉链子时救回
#
# 安全：keeper 不需要任何特权。请在 contracts/.env 里单独放一个
#       KEEPER_PRIVATE_KEY（低额账户，只用来付 gas）。脚本会优先用它；
#       找不到才回退到部署者 PRIVATE_KEY，并在日志里持续告警——
#       因为 cast 只接受 --private-key，密钥会出现在本机进程命令行里，
#       用部署者密钥意味着一旦本机被入侵，owner 权限一起丢。
#
# 退出码恒为 0：计划任务里失败不该反复弹窗，问题一律记进日志。

# -Force：跳过「每 10 分钟才扫一次卡住的期」的节流，用于手动排查与验证。
#         正常计划任务不要带这个开关，会白白增加公共 RPC 调用。
param([switch]$Force)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$logFile = Join-Path $PSScriptRoot 'keeper.log'
$castExe = Join-Path $env:USERPROFILE '.foundry\bin\cast.exe'

function Write-Log([string]$msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { Add-Content -Path $logFile -Value $line -Encoding utf8 } catch { }
}

# 日志滚动：超过 1MB 只留最后 500 行，免得计划任务跑几个月撑爆磁盘
function Invoke-LogRotation {
    if (-not (Test-Path $logFile)) { return }
    $size = (Get-Item $logFile).Length
    if ($size -lt 1MB) { return }
    $tail = Get-Content $logFile -Tail 500
    Set-Content -Path $logFile -Value $tail -Encoding utf8
}

function Read-DotEnv([string]$path) {
    $map = @{}
    if (-not (Test-Path $path)) { return $map }
    foreach ($line in Get-Content $path) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim()
        $v = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
        $map[$k] = $v
    }
    return $map
}

# cast 的包装：失败不抛，返回 $null，由调用方决定怎么处理
function Invoke-Cast([string[]]$castArgs) {
    $out = & $castExe @castArgs
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out | Out-String).Trim()
}

try {
    Invoke-LogRotation

    if (-not (Test-Path $castExe)) {
        Write-Log "ERROR cast 未找到：$castExe（先装 foundry）"
        exit 0
    }

    $envMap = Read-DotEnv (Join-Path $repo 'contracts\.env')
    $rpc = $envMap['BASE_SEPOLIA_RPC_URL']
    if ([string]::IsNullOrWhiteSpace($rpc)) {
        Write-Log 'ERROR contracts/.env 里没有 BASE_SEPOLIA_RPC_URL'
        exit 0
    }

    $pk = $envMap['KEEPER_PRIVATE_KEY']
    if ([string]::IsNullOrWhiteSpace($pk)) {
        $pk = $envMap['PRIVATE_KEY']
        Write-Log 'WARN  未设置 KEEPER_PRIVATE_KEY，正在使用部署者私钥。keeper 不需要任何特权，请改用独立低额账户'
    }
    if ([string]::IsNullOrWhiteSpace($pk)) {
        Write-Log 'ERROR contracts/.env 里既没有 KEEPER_PRIVATE_KEY 也没有 PRIVATE_KEY'
        exit 0
    }

    $deployPath = Join-Path $repo 'web\src\lib\deployment.base-sepolia.json'
    if (-not (Test-Path $deployPath)) {
        Write-Log "ERROR 找不到部署配置：$deployPath"
        exit 0
    }
    $lottery = (Get-Content $deployPath -Raw | ConvertFrom-Json).lottery
    if ([string]::IsNullOrWhiteSpace($lottery)) {
        Write-Log 'ERROR 部署配置里没有 lottery 地址'
        exit 0
    }

    # ---- 1. 到点开奖 ----
    $needed = Invoke-Cast @('call', $lottery, 'checkUpkeep(bytes)(bool,bytes)', '0x', '--rpc-url', $rpc)
    if ($null -eq $needed) {
        Write-Log 'WARN  checkUpkeep 读取失败（RPC 波动），本次跳过'
        exit 0
    }

    if ($needed -match '(?m)^\s*true\s*$') {
        Write-Log "开奖到期，发送 performUpkeep -> $lottery"
        $send = Invoke-Cast @(
            'send', $lottery, 'performUpkeep(bytes)', '0x',
            '--private-key', $pk, '--rpc-url', $rpc
        )
        if ($null -eq $send) {
            # 常见且无害：别人抢先开了、或 RPC 短暂不可用。下一次巡检自然纠正
            Write-Log 'WARN  performUpkeep 失败（可能已被他人触发），下次巡检重试'
        }
        else {
            $txLine = ($send -split "`n" | Where-Object { $_ -match 'transactionHash' }) -join ''
            Write-Log "OK    开奖已触发 $txLine"
        }
    }

    # ---- 2. 卡住的期兜底重试（每 10 分钟查一次，别把公共 RPC 打满）----
    if ((-not $Force) -and ((Get-Date).Minute % 10 -ne 0)) { exit 0 }

    $curRaw = Invoke-Cast @('call', $lottery, 's_currentRound()(uint32)', '--rpc-url', $rpc)
    if ($null -eq $curRaw) { exit 0 }
    $cur = [uint32]($curRaw -replace '[^\d].*$', '')
    $now = [int64][double]::Parse((Get-Date -UFormat %s))
    $timeout = 3 * 60 * 60 # 合约 DRAW_TIMEOUT

    $from = [Math]::Max(1, $cur - 5)
    for ($id = $from; $id -le $cur; $id++) {
        $r = Invoke-Cast @(
            'call', $lottery,
            'getRound(uint32)(uint8,uint64,uint64,uint32,uint256,uint256,uint256,uint16,bool)',
            "$id", '--rpc-url', $rpc
        )
        if ($null -eq $r) { continue }
        $state = ($r -split "`n")[0].Trim()
        if ($state -ne '2') { continue } # 只关心 DRAWING

        $req = Invoke-Cast @('call', $lottery, 'vrfRequestOf(uint32)(uint256,uint64)', "$id", '--rpc-url', $rpc)
        if ($null -eq $req) { continue }
        $lines = $req -split "`n"
        if ($lines.Count -lt 2) { continue }
        $requestedAt = [int64](($lines[1] -replace '[^\d].*$', '').Trim())
        if ($requestedAt -eq 0) { $requestedAt = 0 }
        if (($now - $requestedAt) -lt $timeout) { continue }

        Write-Log "第 $id 期卡在 DRAWING 超过 3 小时，发送 retryDraw"
        $retry = Invoke-Cast @(
            'send', $lottery, 'retryDraw(uint32)', "$id",
            '--private-key', $pk, '--rpc-url', $rpc
        )
        if ($null -eq $retry) { Write-Log "WARN  第 $id 期 retryDraw 失败，下次再试" }
        else { Write-Log "OK    第 $id 期已重新请求随机数" }
    }
}
catch {
    Write-Log ("ERROR 未预期异常：" + $_.Exception.Message)
}

exit 0
