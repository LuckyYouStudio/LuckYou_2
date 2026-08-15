# 多期验证驱动器（仅测试网）
#
# 和 keeper.ps1 的分工要说清楚：keeper 是**生产**组件，只做一件事——到点触发开奖。
# 本脚本是**验证台**，除了触发开奖还会自动买票。绝不能把买票逻辑塞进 keeper：
# 生产 keeper 里出现「自动买彩票」的代码是错的，而且会让它的权限面和资金面无谓扩大。
#
# 为什么必须自动买票：没人买票的期会以 ticketCount == 0 走 VOIDED，
# 那样跑一百期也只验证了 VOID 这一条路径，开奖/滚存/领奖/开奖激励全都碰不到。
#
# 硬闸：chainId 必须是 84532（Base Sepolia）。主网上跑这个脚本没有任何意义，
# 因此宁可硬编码拒绝，也不留一个「配置对了就能跑」的口子。
#
# 退出码恒为 0：计划任务里失败不该反复弹窗，问题一律记进日志。
# 密钥策略与 keeper.ps1 一致：**绝不回退到部署者 PRIVATE_KEY**。

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$log  = Join-Path $PSScriptRoot 'validation-driver.log'

function Write-Log([string]$m) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding utf8
}

try {
    # ---- 读 .env（不落盘、不进命令行）----
    $envMap = @{}
    Get-Content (Join-Path $root 'contracts\.env') | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') {
            $envMap[$Matches[1]] = $Matches[2].Trim().Trim('"')
        }
    }

    $dep = Get-Content (Join-Path $root 'web\src\lib\deployment.base-sepolia.json') -Raw | ConvertFrom-Json
    if ($dep.chainId -ne 84532) { Write-Log "ABORT  chainId $($dep.chainId) 不是 Base Sepolia，拒绝运行"; exit 0 }
    $L = $dep.lottery
    $rpc = if ($envMap['RPC_URL']) { $envMap['RPC_URL'] } else { 'https://base-sepolia-rpc.publicnode.com' }

    $cast = Join-Path $env:USERPROFILE '.foundry\bin\cast.exe'
    if (-not (Test-Path $cast)) { Write-Log 'ABORT  找不到 cast.exe'; exit 0 }

    # ---- 签名密钥：keystore 优先，绝不回退到部署者私钥 ----
    $signArgs = $null
    $acct = $envMap['KEEPER_ACCOUNT']
    $pwFile = $envMap['KEEPER_PASSWORD_FILE']
    if ($acct -and $pwFile -and (Test-Path $pwFile)) {
        $signArgs = @('--account', $acct, '--password-file', $pwFile)
    } elseif ($envMap['KEEPER_PRIVATE_KEY']) {
        $signArgs = @('--private-key', $envMap['KEEPER_PRIVATE_KEY'])
        Write-Log 'WARN  正在用原始私钥签名，它会出现在本机进程命令行里。建议改用 keystore'
    } else {
        Write-Log 'ERROR 未配置驱动器签名密钥（KEEPER_ACCOUNT + KEEPER_PASSWORD_FILE，或 KEEPER_PRIVATE_KEY）。**不会回退到部署者 PRIVATE_KEY**'
        exit 0
    }

    function Cast-Call([string[]]$a) { & $cast call $L @a --rpc-url $rpc --block latest 2>&1 }
    function Cast-Send([string[]]$a) { & $cast send $L @a --rpc-url $rpc @signArgs 2>&1 }

    # ---- ① 到点就开奖（顺带验证 FR-C-30 开奖激励）----
    $need = (Cast-Call @('checkUpkeep(bytes)(bool,bytes)', '0x')) | Select-Object -First 1
    if ("$need".Trim() -eq 'true') {
        Write-Log 'DRAW   到期，触发 performUpkeep'
        $r = Cast-Send @('performUpkeep(bytes)', '0x')
        if ("$r" -match 'status\s+1') { Write-Log 'DRAW   成功' } else { Write-Log "DRAW   失败：$r" }
    }

    # ---- ② 让当前期有票可开 ----
    # 目标票数刻意不取整：让每期票数不同，中奖票号分布、取整余数、配比释放
    # 才会真正被走到不同分支，而不是每期都撞同一个数
    $round = ("" + (Cast-Call @('s_currentRound()(uint32)'))).Trim()
    $info  = Cast-Call @('getRound(uint32)(uint8,uint64,uint64,uint32,uint256,uint256,uint256,uint16,bool)', $round)
    $state = [int](("" + $info[0]).Trim())
    $close = [int64](("" + $info[1]).Trim() -replace '\s.*$','')
    $count = [int](("" + $info[3]).Trim() -replace '\s.*$','')
    $now   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $target = 3 + ([int]$round % 7)   # 3~9 张，随期号变化
    if ($state -eq 0 -and $now -lt $close -and $count -lt $target) {
        $qty = $target - $count
        $price = [decimal](("" + (Cast-Call @('i_ticketPrice()(uint256)'))).Trim() -replace '\s.*$','')
        $wei = [System.Numerics.BigInteger]::Parse(($price * $qty).ToString('F0'))
        Write-Log "BUY    第 $round 期买 $qty 张（现有 $count，目标 $target）"
        # 第二个参数是期号闸（FR-C-09a）。这里现读是可接受的：驱动器就是要买「当前期」，
        # 它没有「下单时看到的期号」这个概念。真实用户走前端，传的是界面上显示的那个
        $r = Cast-Send @('buyTickets(uint32,uint32)', "$qty", "$round", '--value', "$wei")
        if ("$r" -match 'status\s+1') { Write-Log 'BUY    成功' } else { Write-Log "BUY    失败：$r" }
    }
} catch {
    Write-Log "EXCEPTION $($_.Exception.Message)"
}
exit 0
