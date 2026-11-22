# ============================================================
# Windows PowerShell -> Ubuntu 192.168.1.10 SSH 免密登录配置
# 适用：Windows 10 1809+ / Windows 11（系统自带 OpenSSH 客户端）
# 用法：1) 修改 $TargetUser 为 Ubuntu 实际用户名
#      2) 普通权限打开 PowerShell，整段粘贴执行
#      3) 首次会提示输入目标机密码
# 特性：幂等、不覆盖已有密钥、公钥去重、全程错误检查
# 注意：不要用 $HOST 当变量名（PowerShell 保留变量），故用 $TargetHost
# ============================================================

$ErrorActionPreference = 'Stop'

# ---------- 配置区（只需改 $TargetUser）----------
$TargetHost = '192.168.1.10'
$TargetUser = 'ubuntu'        # <-- 改成你的 Ubuntu 用户名，如 root / ops
$SshPort    = 22
$KeyName    = 'id_ed25519_lan_10'
$Alias      = 'ubuntu-lan'
# ------------------------------------------------

$sshDir     = Join-Path $HOME '.ssh'
$keyPath    = Join-Path $sshDir $KeyName
$pubPath    = "$keyPath.pub"
$configPath = Join-Path $sshDir 'config'
$keyPathForConfig = $keyPath.Replace('\', '/')   # OpenSSH 配置统一用正斜杠

function Write-OK   { param([string]$m) Write-Host "[OK]   $m" -ForegroundColor Green }
function Write-Fail { param([string]$m) Write-Host "[FAIL] $m" -ForegroundColor Red }

# 0) 前置检查：确认系统带 OpenSSH 客户端
foreach ($exe in @('ssh', 'ssh-keygen')) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        throw "未找到 $exe。请到【设置 -> 应用 -> 可选功能 -> 添加功能】安装 'OpenSSH 客户端'，或安装 Git for Windows。"
    }
}
Write-OK ('OpenSSH 客户端就绪: ' + (Get-Command ssh).Source)

# 1) 确保 ~/.ssh 目录存在
if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}

# 2) 幂等生成 ed25519 密钥对
#    PowerShell 传空口令必须写 -N '""'，直接写 -N '' 会被吞掉参数导致交互卡住
if ((Test-Path $keyPath) -and (Test-Path $pubPath)) {
    Write-OK "复用已有密钥: $keyPath"
}
elseif ((Test-Path $keyPath) -or (Test-Path $pubPath)) {
    throw "检测到残缺密钥文件 $keyPath，请手动删除后重试。"
}
else {
    & ssh-keygen -t ed25519 -N '""' -C "lan-$TargetHost-$([DateTime]::Now.ToString('yyyyMMdd'))" -f $keyPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen 失败，退出码 $LASTEXITCODE" }
    Write-OK "密钥已生成: $keyPath"
}

# 3) 端口连通性预检
$portOpen = Test-NetConnection -ComputerName $TargetHost -Port $SshPort -WarningAction SilentlyContinue -InformationLevel Quiet
if (-not $portOpen) { throw "目标机 ${TargetHost}:${SshPort} 不通，请检查网络、防火墙或目标机 sshd 服务。" }
Write-OK "目标机 ${TargetHost}:${SshPort} 可达"

# 4) 读取并校验公钥内容
$pubKey = (Get-Content -Path $pubPath -Raw).Trim()
if (-not $pubKey.StartsWith('ssh-ed25519')) { throw "公钥格式异常: $pubPath" }

# 5) 投递公钥（先检查是否已存在，避免重复追加）
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
    if ($LASTEXITCODE -ne 0) { throw "公钥写入失败，退出码 $LASTEXITCODE" }
    Write-OK "公钥已写入目标机 authorized_keys"
}

# 6) 验证免密登录（BatchMode 禁止交互输密码）
$verify = & ssh -p $SshPort -i $keyPath -o BatchMode=yes -o ConnectTimeout=10 `
    "$TargetUser@$TargetHost" "echo LOGIN_OK; hostname; whoami"
if ($LASTEXITCODE -ne 0 -or $verify -notcontains 'LOGIN_OK') {
    throw "免密验证失败，原始输出: $($verify -join ' | ')"
}
Write-OK ('免密验证通过: ' + ($verify -join ' / '))

# 7) 写入 ~/.ssh/config 别名（幂等）
$block = @"

Host $Alias
    HostName $TargetHost
    Port $SshPort
    User $TargetUser
    IdentityFile $keyPathForConfig
    IdentitiesOnly yes
    ServerAliveInterval 60
"@

$existing = if (Test-Path $configPath) { Get-Content $configPath -Raw } else { '' }
if ($existing -notmatch "(?m)^Host\s+$([regex]::Escape($Alias))\s*$") {
    # ASCII 编码追加，避免 PowerShell 5.1 写入 UTF-8 BOM 导致 ssh 解析 config 失败
    Add-Content -Path $configPath -Value $block -Encoding ascii
    Write-OK "已写入别名配置: $configPath"
}
else {
    Write-OK "别名 $Alias 已存在，跳过写入"
}

Write-OK "全部完成！以后直接执行： ssh $Alias"
