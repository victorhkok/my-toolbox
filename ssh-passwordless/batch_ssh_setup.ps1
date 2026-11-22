<#
.SYNOPSIS
    批量配置 SSH 免密登录（Windows PowerShell 5.1+，系统自带 OpenSSH）

.DESCRIPTION
    1. 所有目标参数（IP / 端口 / 用户名 / 密钥 / 别名）全部变量化
    2. 支持 CSV 和 TXT 两种主机清单格式批量配置
    3. 自动检测已免密主机并跳过（幂等，可重复运行）
    4. 通过 SSH_ASKPASS 机制自动应答密码：
       - 清单里填了统一密码 → 全自动批量
       - 没填密码 + -Interactive 参数 → 逐台提示输入
    5. 详细日志 + CSV 结果报告

.PARAMETER HostList
    主机清单路径（.csv 或 .txt），相对路径基于本脚本目录

.PARAMETER Password
    统一密码，覆盖配置区和清单里的密码（注意：会出现在命令行历史中）

.PARAMETER Interactive
    对未提供密码的主机逐台交互提示输入

.EXAMPLE
    .\batch_ssh_setup.ps1
    .\batch_ssh_setup.ps1 -HostList hosts.csv -Interactive
    .\batch_ssh_setup.ps1 -HostList hosts.txt -Password 'YourPassword'

.NOTES
    安全说明：为免交互，连接时使用 StrictHostKeyChecking=no + UserKnownHostsFile=NUL，
    即不校验主机指纹，仅适合可信内网环境。生产公网环境请改用带外验证主机指纹。
    密码仅写入临时文件并在 finally 中立即删除，不落盘到日志。
#>

[CmdletBinding()]
param(
    [string]$HostList,
    [string]$Password,
    [switch]$Interactive
)

$ErrorActionPreference = 'Stop'

# ============================================================
# 配置区：所有目标参数都在这里，也可通过命令行参数覆盖
# ============================================================
$CONFIG = @{
    HostListFile    = 'hosts_example.csv'   # 默认主机清单（相对本脚本目录）
    DefaultPort     = 22                    # 默认 SSH 端口
    DefaultUser     = 'youruser'          # 默认用户名
    KeyPath         = "$HOME\.ssh\id_ed25519"  # 本机私钥（公钥需同名 .pub）
    UnifiedPassword = ''                    # 统一密码；留空则逐台提示（需 -Interactive）
    AliasPrefix     = ''                    # 别名前缀，例如 'prod-' → 别名 prod-<Host>
    SkipIfAuthorized = $true                # 已免密的主机是否跳过
    SSHTimeoutSec   = 15                    # 单台 SSH 连接超时（秒）
}
# ============================================================

# 命令行参数覆盖配置
if ($PSBoundParameters.ContainsKey('HostList')) { $CONFIG.HostListFile = $HostList }
if ($PSBoundParameters.ContainsKey('Password')) { $CONFIG.UnifiedPassword = $Password }

# 路径解析：相对路径基于脚本目录
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not [System.IO.Path]::IsPathRooted($CONFIG.HostListFile)) {
    $CONFIG.HostListFile = Join-Path $scriptDir $CONFIG.HostListFile
}
$script:LogFile    = Join-Path $scriptDir 'batch_ssh_setup.log'
$script:ReportFile = Join-Path $scriptDir 'batch_ssh_report.csv'

# ---------- 日志函数：屏幕 + 文件双输出 ----------
function Write-Log {
    param(
        [string]$Level,
        [string]$Message,
        [string]$Color = 'White'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $Color
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}
function Log-OK   { param([string]$m) Write-Log 'OK'    $m 'Green'  }
function Log-Warn { param([string]$m) Write-Log 'WARN'  $m 'Yellow' }
function Log-Err  { param([string]$m) Write-Log 'ERROR' $m 'Red'    }
function Log-Info { param([string]$m) Write-Log 'INFO'  $m 'White'  }

# ---------- 解析主机清单 ----------
function Import-HostList {
    param([string]$Path)

    if (-not (Test-Path $Path)) { throw "主机清单不存在: $Path" }

    $ext  = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $list = New-Object System.Collections.Generic.List[object]

    if ($ext -eq '.csv') {
        # CSV 列：Host(必填), Port, User, Alias, Password（均可空，空则用默认值）
        $rows = Import-Csv -Path $Path -Encoding UTF8
        foreach ($row in $rows) {
            if ([string]::IsNullOrWhiteSpace($row.Host)) { continue }

            $hPort = $CONFIG.DefaultPort
            if (-not [string]::IsNullOrWhiteSpace($row.Port)) {
                $hPort = [int]($row.Port.Trim())
            }

            $hUser = $CONFIG.DefaultUser
            if (-not [string]::IsNullOrWhiteSpace($row.User)) {
                $hUser = $row.User.Trim()
            }

            $hAlias = ''
            if (-not [string]::IsNullOrWhiteSpace($row.Alias)) {
                $hAlias = $row.Alias.Trim()
            }

            $hPwd = $CONFIG.UnifiedPassword
            if (-not [string]::IsNullOrWhiteSpace($row.Password)) {
                $hPwd = $row.Password
            }

            $list.Add([PSCustomObject]@{
                Host     = $row.Host.Trim()
                Port     = $hPort
                User     = $hUser
                Alias    = $hAlias
                Password = $hPwd
            })
        }
    }
    else {
        # TXT 每行一种格式，支持 # 注释和空行：
        #   host
        #   host:port
        #   user@host
        #   user@host:port
        foreach ($raw in (Get-Content -Path $Path -Encoding UTF8)) {
            $line = $raw.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }

            $hUser = $CONFIG.DefaultUser
            $hPort = $CONFIG.DefaultPort
            $rest  = $line

            if ($line -match '^([^@\s]+)@(.+)$') {
                $hUser = $Matches[1]
                $rest  = $Matches[2]
            }
            if ($rest -match '^(.+):(\d+)$') {
                $rest  = $Matches[1]
                $hPort = [int]$Matches[2]
            }

            $list.Add([PSCustomObject]@{
                Host     = $rest.Trim()
                Port     = $hPort
                User     = $hUser
                Alias    = ''
                Password = $CONFIG.UnifiedPassword
            })
        }
    }

    if ($list.Count -eq 0) { throw "主机清单为空或格式错误: $Path" }
    # 用 unary comma 强制返回数组，避免单台主机时被 PowerShell 解包成单个对象
    return ,($list.ToArray())
}

# ---------- 用 SSH_ASKPASS 自动应答密码执行 SSH 命令 ----------
function Invoke-SSHWithPassword {
    param(
        [string]$TargetHost,
        [string]$TargetUser,
        [int]$TargetPort,
        [string]$TargetPassword,
        [string]$RemoteCommand
    )

    if ([string]::IsNullOrEmpty($TargetPassword)) {
        throw "未提供密码，无法连接 $TargetUser@$TargetHost"
    }

    # 密码写入临时文件（随机名），askpass 批处理用 type 输出，规避 cmd 特殊字符转义问题
    $token     = [guid]::NewGuid().ToString('N')
    $pwdFile   = Join-Path ([System.IO.Path]::GetTempPath()) "sshpwd_$token.txt"
    $askpass   = Join-Path ([System.IO.Path]::GetTempPath()) "sshask_$token.bat"

    try {
        [System.IO.File]::WriteAllText($pwdFile, $TargetPassword)
        [System.IO.File]::WriteAllText($askpass, "@echo off`r`ntype `"$pwdFile`"", [System.Text.Encoding]::ASCII)

        $sshExe = (Get-Command ssh -ErrorAction Stop).Source
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $sshExe
        # 强制密码认证、不校验主机指纹（内网可信环境）、单次密码尝试
        $psi.Arguments = "-p $TargetPort " +
            "-o StrictHostKeyChecking=no " +
            "-o UserKnownHostsFile=NUL " +
            "-o PreferredAuthentications=password,keyboard-interactive " +
            "-o PubkeyAuthentication=no " +
            "-o NumberOfPasswordPrompts=1 " +
            "-o ConnectTimeout=$($CONFIG.SSHTimeoutSec) " +
            "$TargetUser@$TargetHost `"$RemoteCommand`""
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true

        # SSH_ASKPASS 触发条件：设置了 DISPLAY + stdin 非 tty + SSH_ASKPASS 指向取密码程序
        $psi.EnvironmentVariables['SSH_ASKPASS']         = $askpass
        $psi.EnvironmentVariables['DISPLAY']             = ':0'
        $psi.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        if (-not $proc.Start()) { throw "无法启动 ssh 进程" }
        $proc.StandardInput.Close()   # 关闭 stdin，强制走 askpass

        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()

        if (-not $proc.WaitForExit(($CONFIG.SSHTimeoutSec + 10) * 1000)) {
            try { $proc.Kill() } catch { }
            throw "SSH 执行超时 ($($CONFIG.SSHTimeoutSec) 秒)"
        }

        return [PSCustomObject]@{
            Success  = ($proc.ExitCode -eq 0)
            ExitCode = $proc.ExitCode
            Output   = $stdout
            Error    = $stderr
        }
    }
    finally {
        Remove-Item $pwdFile -Force -ErrorAction SilentlyContinue
        Remove-Item $askpass -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 测试是否已免密（BatchMode 禁止交互） ----------
function Test-PasswordlessSSH {
    param(
        [string]$TargetHost,
        [string]$TargetUser,
        [int]$TargetPort,
        [string]$KeyPath
    )

    $marker = '__SSH_PING_OK__'
    # PowerShell 5.1 在 ErrorActionPreference=Stop 下会把 ssh 的 stderr（如 host key warning）
    # 当成终止性错误，故此处临时降级为 Continue，靠 $LASTEXITCODE 判断结果
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $result = & ssh -p $TargetPort -i $KeyPath `
            -o BatchMode=yes `
            -o StrictHostKeyChecking=no `
            -o UserKnownHostsFile=NUL `
            -o "ConnectTimeout=$($CONFIG.SSHTimeoutSec)" `
            "$TargetUser@$TargetHost" "echo $marker" 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldEap
    }

    return ($exitCode -eq 0 -and (($result -join ' ') -match $marker))
}

# ---------- 投递公钥（去重，幂等） ----------
function Install-PublicKey {
    param(
        [string]$TargetHost,
        [string]$TargetUser,
        [int]$TargetPort,
        [string]$PubKeyValue,
        [string]$TargetPassword
    )

    # 用 { ...; } 分组保证 grep 失败才追加，chmod 始终执行
    $cmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && { grep -qxF '$PubKeyValue' ~/.ssh/authorized_keys 2>/dev/null || printf '%s\n' '$PubKeyValue' >> ~/.ssh/authorized_keys; } && chmod 600 ~/.ssh/authorized_keys"

    return Invoke-SSHWithPassword -TargetHost $TargetHost -TargetUser $TargetUser `
        -TargetPort $TargetPort -TargetPassword $TargetPassword -RemoteCommand $cmd
}

# ---------- 写入/更新 ssh config 别名 ----------
function Add-SSHConfigAlias {
    param(
        [string]$Alias,
        [string]$TargetHost,
        [string]$TargetUser,
        [int]$TargetPort,
        [string]$KeyPath
    )

    if ([string]::IsNullOrWhiteSpace($Alias)) { return }

    $configPath = Join-Path $HOME '.ssh\config'
    $dir = Split-Path $configPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $content = if (Test-Path $configPath) { [System.IO.File]::ReadAllText($configPath) } else { '' }
    $escaped = [regex]::Escape($Alias)
    $block = "Host $Alias`n    HostName $TargetHost`n    Port $TargetPort`n    User $TargetUser`n" +
             "    IdentityFile $($KeyPath.Replace('\','/'))`n    IdentitiesOnly yes`n    ServerAliveInterval 60`n"

    if ($content -match "(?m)^Host\s+$escaped\s*$") {
        # 已存在则整段替换
        $content = [regex]::Replace($content, "(?ms)^Host\s+$escaped\s*$.*?(?=^Host\s|\z)", $block)
    }
    else {
        $content = $content.TrimEnd() + "`n`n" + $block
    }

    [System.IO.File]::WriteAllText($configPath, $content, [System.Text.Encoding]::ASCII)
}

# ============================================================
# 主流程
# ============================================================
try {
    try {
        ('=== 批量 SSH 免密配置开始 {0} ===' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) |
            Set-Content -Path $script:LogFile -Encoding UTF8 -ErrorAction Stop
    } catch { }

    Log-Info "主机清单: $($CONFIG.HostListFile)"
    Log-Info "默认用户: $($CONFIG.DefaultUser)  默认端口: $($CONFIG.DefaultPort)"

    # 0) 前置检查
    foreach ($exe in @('ssh', 'ssh-keygen')) {
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
            throw "未找到 $exe。请安装 OpenSSH 客户端（设置 -> 应用 -> 可选功能）。"
        }
    }

    $priv = $CONFIG.KeyPath
    $pub  = "$priv.pub"
    if (-not (Test-Path $priv) -or -not (Test-Path $pub)) {
        throw "密钥不存在: $priv / $pub。请先生成：ssh-keygen -t ed25519 -f `"$priv`""
    }
    $pubKey = ([System.IO.File]::ReadAllText($pub, [System.Text.Encoding]::UTF8)).Trim()
    if (-not $pubKey.StartsWith('ssh-')) { throw "公钥格式异常: $pub" }
    Log-OK "使用本机密钥: $priv"

    # 1) 读取主机清单
    $hosts = Import-HostList -Path $CONFIG.HostListFile
    Log-Info "共读取 $($hosts.Count) 台主机"

    $results = New-Object System.Collections.Generic.List[object]

    # 2) 逐台处理
    foreach ($h in $hosts) {
        $tag = "$($h.User)@$($h.Host):$($h.Port)"
        Log-Info "----- 处理 $tag -----"

        $item = [PSCustomObject]@{
            Host     = $h.Host
            Port     = $h.Port
            User     = $h.User
            Alias    = $h.Alias
            Status   = ''
            Message  = ''
        }

        # 2.1 已免密则跳过
        if ($CONFIG.SkipIfAuthorized -and (Test-PasswordlessSSH -TargetHost $h.Host -TargetUser $h.User -TargetPort $h.Port -KeyPath $priv)) {
            $item.Status  = 'SKIPPED'
            $item.Message = '已免密，跳过'
            Log-OK "$tag 已免密，跳过"
            $results.Add($item)
            continue
        }

        # 2.2 获取密码
        $pwd = $h.Password
        if ([string]::IsNullOrEmpty($pwd)) {
            if ($Interactive) {
                $secure = Read-Host "请输入 $tag 的密码" -AsSecureString
                $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
                $pwd    = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
            else {
                $item.Status  = 'NO_PASSWORD'
                $item.Message = '未提供密码（加 -Interactive 或 -Password，或在清单 Password 列填写）'
                Log-Warn "$tag $($item.Message)"
                $results.Add($item)
                continue
            }
        }

        # 2.3 投递公钥
        try {
            $install = Install-PublicKey -TargetHost $h.Host -TargetUser $h.User `
                -TargetPort $h.Port -PubKeyValue $pubKey -TargetPassword $pwd
        }
        catch {
            $item.Status  = 'FAILED'
            $item.Message = "投递异常: $($_.Exception.Message)"
            Log-Err "$tag $($item.Message)"
            $results.Add($item)
            continue
        }

        if (-not $install.Success) {
            $errText = ($install.Error -split "`n" | Select-Object -Last 1)
            $item.Status  = 'FAILED'
            $item.Message = "认证/连接失败: $errText"
            Log-Err "$tag $($item.Message)"
            $results.Add($item)
            continue
        }

        # 2.4 验证免密
        if (Test-PasswordlessSSH -TargetHost $h.Host -TargetUser $h.User -TargetPort $h.Port -KeyPath $priv) {
            $item.Status  = 'SUCCESS'
            $item.Message = '公钥已投递，免密验证通过'

            # 2.5 写别名（清单没填则用 Host 名，非法字符替换为下划线）
            $alias = $h.Alias
            if ([string]::IsNullOrWhiteSpace($alias) -and -not [string]::IsNullOrWhiteSpace($CONFIG.AliasPrefix)) {
                $alias = $CONFIG.AliasPrefix + ($h.Host -replace '[^A-Za-z0-9_-]', '_')
            }
            if (-not [string]::IsNullOrWhiteSpace($alias)) {
                Add-SSHConfigAlias -Alias $alias -TargetHost $h.Host -TargetUser $h.User `
                    -TargetPort $h.Port -KeyPath $priv
                $item.Alias = $alias
                $item.Message += "；别名: ssh $alias"
            }
            Log-OK "$tag $($item.Message)"
        }
        else {
            $item.Status  = 'VERIFY_FAILED'
            $item.Message = '公钥已投递，但免密验证未通过（检查目标机 authorized_keys 权限）'
            Log-Warn "$tag $($item.Message)"
        }

        $results.Add($item)
    }

    # 3) 导出 CSV 报告
    $results | Export-Csv -Path $script:ReportFile -NoTypeInformation -Encoding UTF8
    Log-Info "结果报告: $script:ReportFile"

    # 4) 汇总
    Log-Info "========== 汇总 =========="
    foreach ($g in ($results | Group-Object Status)) {
        Log-Info ("  {0}: {1} 台" -f $g.Name, $g.Count)
    }

    Write-Host ""
    $results | Select-Object Host, Port, User, Alias, Status, Message |
        Format-Table -AutoSize | Out-Host
}
catch {
    Log-Err ("致命错误: " + $_.Exception.Message)
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Log-Err ("出错位置: " + ($_.InvocationInfo.PositionMessage -replace "`r?`n", ' '))
    }
}
finally {
    Log-Info "脚本结束，日志: $script:LogFile"
    if ([Environment]::UserInteractive) {
        try {
            Write-Host ""
            Read-Host "执行完毕，按回车键退出..." | Out-Null
        } catch { }
    }
}
