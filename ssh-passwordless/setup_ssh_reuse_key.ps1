# ============================================================
# Windows PowerShell -> Ubuntu 复用【已有 SSH 密钥】配置免密（增强版）
# 场景：本机 ~/.ssh 下已有 id_ed25519 / id_rsa 等密钥，不想重复生成
# 特性：自动探测已有密钥、幂等投递、公钥去重、不覆盖任何文件
#       【新增】全程日志 + 错误捕获 + 结束暂停，解决"一闪而过"看不到结果
#
# 推荐运行方式：双击同目录的 run_ssh_setup.cmd（自动绕过执行策略并保持窗口）
# 也可在 PowerShell 里手动执行：
#   powershell -ExecutionPolicy Bypass -File ".\setup_ssh_reuse_key.ps1"
# ============================================================

$ErrorActionPreference = 'Stop'

# ---------- 配置区（只需改 $TargetUser）----------
$TargetHost = '192.168.1.10'
$TargetUser = 'youruser'        # <-- 目标机用户名（请改成你的目标机用户名）
$SshPort    = 22
$Alias      = 'ubuntu-lan'
# ------------------------------------------------

$sshDir     = Join-Path $HOME '.ssh'
$configPath = Join-Path $sshDir 'config'
$scriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LogFile    = Join-Path $scriptDir 'ssh_setup.log'

# ---------- 日志函数：屏幕 + 文件双输出 ----------
function Log {
    param(
        [string]$Level,
        [string]$Message,
        [string]$Color = 'White'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $Color
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}
function Write-OK   { param([string]$m) Log 'OK'   $m 'Green'  }
function Write-Warn { param([string]$m) Log 'WARN' $m 'Yellow' }
function Write-Err  { param([string]$m) Log 'ERROR' $m 'Red'   }

# 初始化日志文件（覆盖旧的）
try {
    ('=== SSH 免密配置开始 {0} ===' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) |
        Set-Content -Path $LogFile -Encoding UTF8 -ErrorAction Stop
} catch {
    Write-Host "[WARN] 无法写日志文件 $LogFile ：$($_.Exception.Message)" -ForegroundColor Yellow
}

Write-OK "脚本启动，日志文件: $LogFile"

try {
    # ---------- 0) 前置检查：ssh / ssh-keygen 是否存在 ----------
    foreach ($exe in @('ssh', 'ssh-keygen')) {
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
            throw "未找到 $exe。请到【设置 -> 应用 -> 可选功能】安装 OpenSSH 客户端，或安装 Git for Windows。"
        }
    }
    Write-OK ("OpenSSH 就绪: " + (Get-Command ssh).Source)

    if (-not (Test-Path $sshDir)) { throw "本机不存在 $sshDir，没有可复用的密钥。" }

    # ---------- 1) 按优先级探测已有密钥（公钥 + 对应私钥必须同时存在） ----------
    $chosenPriv = $null
    $chosenPub  = $null

    foreach ($name in @('id_ed25519', 'id_rsa', 'id_ecdsa')) {
        $p   = Join-Path $sshDir $name
        $pub = "$p.pub"
        if ((Test-Path $p) -and (Test-Path $pub)) {
            $chosenPriv = $p
            $chosenPub  = $pub
            break
        }
    }

    # 优先级未命中 -> 扫描其余 *.pub
    if (-not $chosenPriv) {
        foreach ($c in (Get-ChildItem -Path $sshDir -Filter '*.pub' -File | Sort-Object Name)) {
            $priv = $c.FullName -replace '\.pub$', ''
            if (Test-Path $priv) {
                $chosenPriv = $priv
                $chosenPub  = $c.FullName
                break
            }
        }
    }

    if (-not $chosenPriv) {
        throw "未找到可用的已有密钥。请先生成：ssh-keygen -t ed25519 -f `"$sshDir\id_ed25519`""
    }

    Write-OK ("复用已有公钥: " + $chosenPub)
    Write-OK ("对应私钥: " + $chosenPriv)

    # 用 .NET ReadAllText 替代 Get-Content：避免 PowerShell 5.1 在部分权限/编码场景下的读取失败
    $pubKey  = ([System.IO.File]::ReadAllText($chosenPub, [System.Text.Encoding]::UTF8)).Trim()
    $keyType = ($pubKey -split '\s+')[0]
    if ($keyType -notin @('ssh-ed25519','ssh-rsa','ecdsa-sha2-nistp256','ecdsa-sha2-nistp384','ecdsa-sha2-nistp521')) {
        throw "无法识别的公钥类型: $keyType"
    }

    # ---------- 2) 端口连通性预检 ----------
    $portOpen = Test-NetConnection -ComputerName $TargetHost -Port $SshPort -WarningAction SilentlyContinue -InformationLevel Quiet
    if (-not $portOpen) { throw "目标机 ${TargetHost}:${SshPort} 不通，请检查网络/防火墙/sshd。" }
    Write-OK "目标机 ${TargetHost}:${SshPort} 可达"

    # ---------- 3) 投递公钥：先去重检查，避免重复追加 ----------
    $checkCmd = "grep -qxF '$pubKey' ~/.ssh/authorized_keys 2>/dev/null && echo KEY_EXISTS || echo KEY_MISSING"
    $check = & ssh -p $SshPort -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 `
        "$TargetUser@$TargetHost" $checkCmd
    if ($LASTEXITCODE -ne 0) {
        throw "无法连接目标机（用户名/密码/host key 问题），原始输出: $($check -join ' | ')"
    }

    if ($check -contains 'KEY_EXISTS') {
        Write-OK "公钥已在目标机 authorized_keys 中，跳过投递"
    }
    else {
        $addCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && echo '$pubKey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        & ssh -p $SshPort "$TargetUser@$TargetHost" $addCmd
        if ($LASTEXITCODE -ne 0) { throw "公钥投递失败，退出码 $LASTEXITCODE" }
        Write-OK "公钥已追加到目标机 authorized_keys"
    }

    # ---------- 4) 免密验证（BatchMode 禁止交互输密码） ----------
    $verify = & ssh -p $SshPort -i $chosenPriv -o BatchMode=yes -o ConnectTimeout=10 `
        "$TargetUser@$TargetHost" "echo LOGIN_OK; hostname; whoami"
    if ($LASTEXITCODE -ne 0 -or $verify -notcontains 'LOGIN_OK') {
        Write-Warn "若私钥带口令，请先加载 ssh-agent："
        Write-Host "    Set-Service ssh-agent -StartupType Manual; Start-Service ssh-agent; ssh-add `"$chosenPriv`"" -ForegroundColor Yellow
        throw "免密验证失败，原始输出: $($verify -join ' | ')"
    }
    Write-OK ('免密验证通过: ' + ($verify -join ' / '))

    # ---------- 5) 写入 config 别名（幂等；IdentityFile 指向实际复用的私钥） ----------
    $privForConfig = $chosenPriv.Replace('\', '/')
    $block = @"

Host $Alias
    HostName $TargetHost
    Port $SshPort
    User $TargetUser
    IdentityFile $privForConfig
    IdentitiesOnly yes
    ServerAliveInterval 60
"@

    $existing = if (Test-Path $configPath) { Get-Content $configPath -Raw } else { '' }
    if ($existing -notmatch "(?m)^Host\s+$([regex]::Escape($Alias))\s*$") {
        Add-Content -Path $configPath -Value $block -Encoding ascii
        Write-OK "已写入别名 $Alias -> $privForConfig"
    }
    else {
        Write-Warn "别名 $Alias 已存在，跳过写入；请手动核对 IdentityFile 是否指向 $privForConfig"
    }

    Write-OK "全部完成！以后直接执行： ssh $Alias"
}
catch {
    # 捕获所有异常，打印详细信息到屏幕和日志，绝不静默退出
    Write-Err ("脚本执行失败: " + $_.Exception.Message)
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Err ("出错位置: " + ($_.InvocationInfo.PositionMessage -replace "`r?`n", ' '))
    }
}
finally {
    Log 'INFO' ("脚本结束，日志: " + $LogFile)
    if ([Environment]::UserInteractive) {
        try {
            Write-Host ""
            Read-Host "执行完毕（成功或失败请看上面日志），按回车键退出..." | Out-Null
        } catch { }
    }
}
