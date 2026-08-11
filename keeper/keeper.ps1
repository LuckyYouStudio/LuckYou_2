# LuckYou 自托管 keeper —— 单次巡检（由 Windows 计划任务反复调用）
#
# 职责（都是合约里**无权限**的函数，任何人可调）：
#   1. checkUpkeep 为真 → performUpkeep：到点开奖并开出下一期
#   2. 有期卡在 DRAWING 且超过 DRAW_TIMEOUT(3h) → retryDraw：VRF 掉链子时救回
#
# 安全：keeper 不需要任何特权，因此**失败关闭**——没有 keeper 专用签名密钥就
#       直接退出，绝不回退到部署者 PRIVATE_KEY。停摆只是开奖延迟（任何人可顶上），
#       而 owner 私钥泄露不可逆。密钥优先走 foundry keystore
#       （KEEPER_ACCOUNT + KEEPER_PASSWORD_FILE），密钥不进进程命令行；
#       退而求其次才用 KEEPER_PRIVATE_KEY。详见 keeper/README.md。
#
# 退出码恒为 0：计划任务里失败不该反复弹窗，问题一律记进日志。

# -Force：跳过「每 10 分钟才扫一次卡住的期」的节流，用于手动排查与验证。
#         正常计划任务不要带这个开关，会白白增加公共 RPC 调用。
# -CheckOnly：**只读**。只报告「现在该不该开奖、有没有期卡住」，不发任何交易，
#         因此**不需要配置任何签名密钥**。手动保底开奖时先跑这个看一眼，
#         真要开奖用前端的「🎰 触发开奖」按钮（走你自己的钱包，机器上不留私钥）。
param([switch]$Force, [switch]$CheckOnly)

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

    # 签名密钥：**失败关闭**。此处曾经写成「找不到就回退到部署者 PRIVATE_KEY，
    # 只记一行 WARN 然后继续」——那等于让一个每分钟触发的无人值守桌面任务
    # 长期经手合约 owner 的私钥（实测跑了 44 次，44 次都在用）。
    # keeper 一个特权都不需要，停摆只是开奖延迟（任何人都能顶上），
    # 而 owner 私钥泄露不可逆，还会直接坐实 SPEC Q9 里那条不可恢复的全局冻结。
    # 所以：宁可停，绝不回退。
    #
    # 优先 keystore：密钥加密存盘，**不会出现在进程命令行里**。
    # （此前 README 声称「cast 只接受 --private-key」——那是错的，
    #   实测 cast send 支持 --keystore / --account / --password-file）
    $signArgs = @()
    $acct = $envMap['KEEPER_ACCOUNT']
    # 只读模式无需签名密钥——这样「查一下该不该开奖」不必先在机器上放钥匙
    $pwFile = $envMap['KEEPER_PASSWORD_FILE']
    $rawPk = $envMap['KEEPER_PRIVATE_KEY']
    if (-not [string]::IsNullOrWhiteSpace($acct) -and -not [string]::IsNullOrWhiteSpace($pwFile)) {
        if (-not (Test-Path $pwFile)) {
            Write-Log "ERROR KEEPER_PASSWORD_FILE 指向的文件不存在：$pwFile"
            exit 0
        }
        $signArgs = @('--account', $acct, '--password-file', $pwFile)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($rawPk)) {
        $signArgs = @('--private-key', $rawPk)
        Write-Log 'WARN  正在用原始私钥签名，它会出现在本机进程命令行里。建议改用 keystore（见 keeper/README.md）'
    }
    elseif ($CheckOnly) {
        $signArgs = $null # 只读，用不到
    }
    else {
        Write-Log 'ERROR 未配置 keeper 签名密钥。请在 contracts/.env 里设置 KEEPER_ACCOUNT + KEEPER_PASSWORD_FILE（推荐）或 KEEPER_PRIVATE_KEY。**不会回退到部署者 PRIVATE_KEY**：keeper 无需任何特权，停摆只是开奖延迟，而 owner 私钥泄露不可逆'
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

    $isDue = $needed -match '(?m)^\s*true\s*$'
    if ($CheckOnly) {
        if ($isDue) { Write-Log "CHECK 开奖已到期，需要有人触发 -> $lottery" }
        else { Write-Log 'CHECK 开奖未到期' }
    }
    elseif ($isDue) {
        Write-Log "开奖到期，发送 performUpkeep -> $lottery"
        $send = Invoke-Cast (@('send', $lottery, 'performUpkeep(bytes)', '0x',
                '--rpc-url', $rpc) + $signArgs)
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
    if ((-not $Force) -and (-not $CheckOnly) -and ((Get-Date).Minute % 10 -ne 0)) { exit 0 }

    $curRaw = Invoke-Cast @('call', $lottery, 's_currentRound()(uint32)', '--rpc-url', $rpc)
    if ($null -eq $curRaw) { exit 0 }
    $cur = [uint32]($curRaw -replace '[^\d].*$', '')
    # 不能用 Get-Date -UFormat %s：PowerShell 5.1 下它返回的是**本地时区**的纪元秒，
    # 本机（UTC+8）实测比真实 UTC 纪元大 28800 秒。用它算 DRAW_TIMEOUT 会让
    # UTC 以东的机器每次都判定「已超时」而徒劳重试，UTC 以西的机器则把 3 小时
    # 兜底拖成 8~11 小时——两种情况都让这条兜底路径静默失效
    $now = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
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

        if ($CheckOnly) {
            Write-Log "CHECK 第 $id 期卡在 DRAWING 超过 3 小时，需要有人调 retryDraw"
            continue
        }
        Write-Log "第 $id 期卡在 DRAWING 超过 3 小时，发送 retryDraw"
        $retry = Invoke-Cast (@('send', $lottery, 'retryDraw(uint32)', "$id",
                '--rpc-url', $rpc) + $signArgs)
        if ($null -eq $retry) { Write-Log "WARN  第 $id 期 retryDraw 失败，下次再试" }
        else { Write-Log "OK    第 $id 期已重新请求随机数" }
    }
}
catch {
    Write-Log ("ERROR 未预期异常：" + $_.Exception.Message)
}

exit 0
