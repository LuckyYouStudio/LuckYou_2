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

    # 领奖/领激励要按「我是谁」判断，所以得先知道签名地址。
    # 从 keystore 反推，不硬编码——换密钥时不改脚本
    $signerAddr = ("" + (& $cast wallet address @signArgs 2>&1)).Trim()
    if ($signerAddr -notmatch '^0x[0-9a-fA-F]{40}$') { Write-Log "ABORT  取签名地址失败：$signerAddr"; exit 0 }

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

    # RoundState 枚举是 NONE=0, OPEN=1, DRAWING=2, ... —— **OPEN 是 1 不是 0**。
    # 这里写错过一次：$state -eq 0 永远不成立，驱动器一张票都不会买，
    # 每期零票 VOID，而日志看起来一切正常。用具名常量而不是裸数字
    $ST_OPEN = 1
    # 目标票数在 3~6 之间随期号循环。这个范围是**算出来的，不是随手取的**：
    # 奖级名额是 [1,2,5]，_settle 里只有 winners > ticketCount 的奖级才不开出、
    # 才会有钱进滚存缓冲区。也就是说**票数必须 < 5，三等奖才开不出**。
    # 而且票价 1e14 因子太多，103 张票在 [6000,2500,1500] 三档下除得干干净净、
    # 余数为 0，指望「取整余数」凑出 carry 是不成立的。
    # 用 % 4 让 3、4 各占四分之一，约每两期就产生一次 carry；下一期消费它时
    # 若超过自售额配比，还会顺带触发 CarryWithheld。原来的 % 7 要等到第 7 期
    # 才出现第一次 3 张——真坏了也得 14 小时后才知道。
    $target = if ($envMap['DRIVER_TARGET']) { [int]$envMap['DRIVER_TARGET'] } else { 3 + ([int]$round % 4) }

    # 心跳：每次运行都留一行。否则「没事可做」和「脚本崩了」在日志里长得一模一样，
    # 而计划任务是看不见的——静默是这类脚本最难排查的失败模式
    Write-Log ("TICK   第 {0} 期 state={1} 票数={2}/{3} 距停售={4}s" -f $round, $state, $count, $target, ($close - $now))

    if ($state -eq $ST_OPEN -and $now -lt $close -and $count -lt $target) {
        $qty = $target - $count
        $price = [decimal](("" + (Cast-Call @('i_ticketPrice()(uint256)'))).Trim() -replace '\s.*$','')
        $wei = [System.Numerics.BigInteger]::Parse(($price * $qty).ToString('F0'))
        Write-Log "BUY    第 $round 期买 $qty 张（现有 $count，目标 $target）"
        # 第二个参数是期号闸（FR-C-09a）。这里现读是可接受的：驱动器就是要买「当前期」，
        # 它没有「下单时看到的期号」这个概念。真实用户走前端，传的是界面上显示的那个
        $r = Cast-Send @('buyTickets(uint32,uint32)', "$qty", "$round", '--value', "$wei")
        if ("$r" -match 'status\s+1') { Write-Log 'BUY    成功' } else { Write-Log "BUY    失败：$r" }
    }

    # ---- ③ 领奖 ----
    # 不领奖的话通过标准第 6 条（「领奖 + 提抽成之后守恒仍成立」）永远走不到，
    # 而且奖金会一直挂着等 90 天过期滚存——那条路验证期内根本等不起。
    # 做法是**先 call 模拟再 send**：不中奖时 claim 会 revert，模拟一次是只读的、
    # 不花 gas，可以避免每期盲发三笔大概率失败的交易。
    $prev = [int]$round - 1
    if ($prev -ge 1) {
        $pinfo = Cast-Call @('getRound(uint32)(uint8,uint64,uint64,uint32,uint256,uint256,uint256,uint16,bool)', "$prev")
        $ST_SETTLED = 3
        if ([int](("" + $pinfo[0]).Trim()) -eq $ST_SETTLED) {
            foreach ($tier in 0, 1, 2) {
                $sim = & $cast call $L 'claim(uint32,uint8)' "$prev" "$tier" --from $signerAddr --rpc-url $rpc 2>&1
                if ($LASTEXITCODE -ne 0) { continue }   # 没中这一档，或已领过
                Write-Log "CLAIM  第 $prev 期 T$tier 可领，发起领奖"
                $r = Cast-Send @('claim(uint32,uint8)', "$prev", "$tier")
                if ("$r" -match 'status\s+1') { Write-Log "CLAIM  T$tier 成功" } else { Write-Log "CLAIM  T$tier 失败：$r" }
            }
        }
    }

    # ---- ④ 领开奖激励（FR-C-30）----
    # 与领奖同理：不领的话 KeeperRewardClaimed 永远不触发，
    # 而观察器的资金守恒用的正是「已领」而非「已计提」，这条路径就一直是空白
    # s_keeperRewards 是 private，没有自动 getter；公开视图是 keeperRewardOf
    $owed = ("" + (Cast-Call @('keeperRewardOf(address)(uint256)', $signerAddr))).Trim() -replace '\s.*$',''
    if ($owed -and [decimal]$owed -gt 0) {
        Write-Log "REWARD 可领开奖激励 $owed wei"
        $r = Cast-Send @('claimKeeperReward()')
        if ("$r" -match 'status\s+1') { Write-Log 'REWARD 成功' } else { Write-Log "REWARD 失败：$r" }
    }
} catch {
    Write-Log "EXCEPTION $($_.Exception.Message)"
}
exit 0
