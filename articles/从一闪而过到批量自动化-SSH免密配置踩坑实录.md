# 从"一闪而过"到批量自动化：一次 Windows 配置 SSH 免密登录的踩坑实录

> 摘要：给局域网 Ubuntu 主机配 SSH 免密，本来以为是三行命令的事，结果踩了一串 PowerShell 的坑。本文完整记录从脚本崩溃、日志都写不出来的"一闪而过"，到最终支持 CSV/TXT 批量配置的全过程，附可直接运行的脚本。全文约 3000 字，建议收藏。

---

## 一、事情是这样开始的

手里有一台局域网 Ubuntu 主机（`192.168.1.10`），日常要经常 SSH 上去操作。每次输密码很烦，于是决定配置公钥免密登录。

思路很简单，四步：

1. 本机生成密钥对
2. 把公钥追加到目标机的 `~/.ssh/authorized_keys`
3. 验证免密
4. 写个 `ssh config` 别名，以后 `ssh ubuntu-lan` 一键连接

在一个 Linux 环境里，这就是 `ssh-keygen` + `ssh-copy-id` 两行命令的事。但我的**本机是 Windows**，麻烦从这里开始。

---

## 二、第一版脚本：本以为十拿九稳

写了个 PowerShell 脚本，逻辑没问题：

```powershell
ssh-keygen -t ed25519 -N '""' -f "$HOME\.ssh\id_ed25519"
$Pub = (Get-Content "$HOME\.ssh\id_ed25519.pub" -Raw).Trim()
ssh user@192.168.1.10 "mkdir -p ~/.ssh; echo '$Pub' >> ~/.ssh/authorized_keys"
```

结果双击运行——**窗口一闪而过，什么都没发生，连日志都没有**。

如果你也遇到过这个现象，恭喜，你踩进了 PowerShell 经典陷阱。

---

## 三、根因：中文乱码引发的"血案"

第一反应是执行策略拦截，但加上 `-ExecutionPolicy Bypass` 还是闪退。于是写了个诊断脚本，用 PowerShell 的 AST 解析器检查语法：

```powershell
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
$errors.Count
```

结果触目惊心：**12 个语法错误**。

```
Line 42: 表达式或语句中包含意外的标记"}"
Line 55: 表达式或语句中包含意外的标记"OpenSSH"
Line 101: 表达式或语句中包含意外的标记"鐩爣鏈?${TargetHost}"
...
```

看到 `鐩爣鏈` 这种乱码就破案了——**PowerShell 5.1 读取 UTF-8 无 BOM 的 `.ps1` 文件时，默认按 GBK 解码**。脚本里的中文注释和输出全部变成乱码，乱码字符里恰好包含引号，把字符串提前闭合了，连锁引发 12 处语法错误。

脚本在**解析阶段**就崩溃，一行都没执行，所以日志当然不会有。

### 解决方案：给文件加 UTF-8 BOM

```powershell
$noBom   = New-Object System.Text.UTF8Encoding($false)
$withBom = New-Object System.Text.UTF8Encoding($true)
$content = [System.IO.File]::ReadAllText($path, $noBom)
[System.IO.File]::WriteAllText($path, $content, $withBom)
```

转换后重新校验：**语法错误 0 个**，文件头 `EF BB BF`（BOM 标志）正确。

同时把 `.cmd` 启动器改成**纯英文**，避免代码页二次干扰。

### 顺带加的三层保险

| 措施 | 作用 |
|---|---|
| `try/catch/finally` 包裹全部逻辑 | 出错时打印错误信息和出错行号，不再静默退出 |
| 屏幕 + 日志文件双输出 | 窗口关了也能回看 `ssh_setup.log` |
| `finally` 里 `Read-Host` 暂停 | 执行完停住等你按回车，绝不"一闪而过" |

---

## 四、又踩三个坑：PowerShell 5.1 的"个性"

修好编码后，实测又暴露了三个问题，都是 5.1 版本的特性坑：

### 坑 1：`$HOST` 是保留变量

```powershell
$HOST = "192.168.1.10"   # ❌ 这是 PowerShell 宿主对象，不是你的变量
```

改成 `$TargetHost` 之类，否则拼出来的字符串是一坨乱码。

### 坑 2：空口令必须写 `-N '""'`

```powershell
ssh-keygen -t ed25519 -N '' -f $key    # ❌ 空字符串参数被吞，交互卡住
ssh-keygen -t ed25519 -N '""' -f $key  # ✅ 传字面量两个引号，被 C runtime 解析为空口令
```

### 坑 3：对象属性在裸参数里不展开

```powershell
-o ConnectTimeout=$CONFIG.Timeout   # ❌ 传给 ssh 的是字面量 "$CONFIG.Timeout"，报 invalid time value
-o "ConnectTimeout=$($CONFIG.Timeout)"  # ✅ 用子表达式展开
```

还有一个更隐蔽的：`$ErrorActionPreference='Stop'` 下，**ssh 写到 stderr 的普通 warning（比如首次连接的 host key 提示）会被当成终止性错误**，导致脚本误判失败。解决办法是在调用 ssh 的局部临时降级为 `Continue`，靠 `$LASTEXITCODE` 判断结果。

---

## 五、需求升级：变量化 + CSV/TXT 批量配置

单台配好后，需求自然升级：能不能把 IP、端口、用户名做成变量？能不能读清单批量配几十台？

### 参数全部变量化

脚本顶部一个 `$CONFIG` 配置区搞定，也支持命令行覆盖：

```powershell
$CONFIG = @{
    HostListFile     = 'hosts.csv'
    DefaultPort      = 22
    DefaultUser      = 'ops'
    KeyPath          = "$HOME\.ssh\id_ed25519"
    UnifiedPassword  = ''
    AliasPrefix      = 'prod-'
    SkipIfAuthorized = $true
    SSHTimeoutSec    = 15
}
```

```powershell
.\batch_ssh_setup.ps1 -HostList hosts.txt -Interactive
```

### 批量配置的核心难题：密码怎么自动输？

Windows 没有 `sshpass`，ssh 的密码从 tty 读取，管道喂不进去。这里用了一个巧招——**SSH_ASKPASS 机制**：

1. 把密码写入随机临时文件
2. 生成一个 askpass 批处理，内容就一句 `type 密码文件`
3. 启动 ssh 时设置 `SSH_ASKPASS` + `DISPLAY=:0`，并**关闭 stdin**
4. ssh 发现 stdin 不是 tty 且设置了 askpass，就自动执行它拿密码
5. `finally` 里立即删除临时文件，密码不落盘到日志

```powershell
$psi.EnvironmentVariables['SSH_ASKPASS'] = $askpass
$psi.EnvironmentVariables['DISPLAY']     = ':0'
$proc.StandardInput.Close()   # 关键：关闭 stdin，强制走 askpass
```

于是支持两种模式：

- **全自动**：清单里填密码或传 `-Password`，几十台机器无人值守批量配置
- **逐台交互**：密码留空 + `-Interactive`，每台弹安全提示输入

### 清单格式

CSV（列：`Host,Port,User,Alias,Password`）：

```csv
Host,Port,User,Alias,Password
192.168.1.10,22,ops,ubuntu-lan,
192.168.1.12,2222,root,server-12,YourPassword
```

TXT（四种写法任选）：

```
192.168.1.10
192.168.1.11:22
ops@192.168.1.12
root@192.168.1.13:2222
```

### 幂等设计

每台机器处理前先用 `BatchMode=yes` 检测是否已免密，**已免密的直接跳过**；公钥投递前先 `grep -qxF` 去重，重复运行不会塞进一堆重复行。最后输出 CSV 结果报告，每台的成功/跳过/失败状态一目了然。

---

## 六、实测结果

```
[OK] 共读取 1 台主机
[OK] youruser@192.168.1.10:22 已免密，跳过
[INFO] ========== 汇总 ==========
[INFO]   SKIPPED: 1 台
```

幂等检测生效，脚本可放心反复运行。

---

## 七、几个值得记住的点

1. **Windows 上跑含中文的 PowerShell 脚本，一定要存成 UTF-8 with BOM**，否则 5.1 按 GBK 解码，中文乱码会引发匪夷所思的语法错误。
2. **"一闪而过"本质是脚本根本没执行**，先做语法解析校验，别急着改执行策略。
3. **给脚本加日志和暂停是性价比最高的容错设计**，能省掉大量"到底哪错了"的猜测。
4. **批量自动化的密码投递用 SSH_ASKPASS**，比在命令行明文传密码安全，也比手动逐台输高效。
5. **幂等是运维脚本的基本修养**：跳过已完成项、去重、写报告，一个都不能少。

> 安全提示：为免交互，脚本使用了 `StrictHostKeyChecking=no`（不校验主机指纹），**仅适合可信内网**。公网环境请预先分发 `known_hosts` 并去掉该参数。

---

## 八、代码托管

完整脚本（单台版 + 批量版 + CSV/TXT 示例 + 启动器）已开源在 GitHub：

**仓库：`victorhkok/my-toolbox`**

```
https://github.com/victorhkok/my-toolbox
```

定位是"常用代码工具箱"，后续还会往里放其他运维脚本。欢迎 Star，有问题提 Issue。

---

*如果这篇帮你少踩了一个坑，点个「在看」吧。*
