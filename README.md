# my-toolbox

> 常用代码工具箱 —— 把日常反复用到的运维脚本、自动化工具集中托管，开箱即用。

![license](https://img.shields.io/badge/license-MIT-blue.svg)
![shell](https://img.shields.io/badge/shell-PowerShell%205.1%2FGit%20Bash-green.svg)
![platform](https://img.shields.io/badge/platform-Windows%20%F0%9F%94%B8%20Linux-orange.svg)

## 📦 当前收录

### 🔐 ssh-passwordless — SSH 免密登录配置工具集

从"一闪而过"的踩坑到批量自动化，一套完整的 Windows → Linux SSH 免密配置方案。

| 文件 | 说明 |
|---|---|
| `setup_ssh_ubuntu_lan.ps1` | 单台配置（新建专用密钥），PowerShell 版 |
| `setup_ssh_ubuntu_lan.sh` | 单台配置（新建专用密钥），Git Bash 版 |
| `setup_ssh_reuse_key.ps1` | 单台配置（复用已有密钥），带日志与异常捕获 |
| `run_ssh_setup.cmd` | 上面脚本的双击启动器（绕过执行策略、保持窗口） |
| `batch_ssh_setup.ps1` | **批量版**：CSV/TXT 清单、参数全变量化、SSH_ASKPASS 自动应答密码 |
| `run_batch_ssh.cmd` | 批量脚本的双击启动器 |
| `hosts_example.csv` / `hosts_example.txt` | 主机清单示例 |
| `article-wechat.md` | 配套公众号文章：《从"一闪而过"到批量自动化》 |

**快速开始（单台）：**

1. 编辑 `setup_ssh_reuse_key.ps1` 顶部配置区的 IP、用户名
2. 双击 `run_ssh_setup.cmd`，首次输入一次目标机密码
3. 完成后 `ssh ubuntu-lan` 免密登录

**快速开始（批量）：**

```powershell
# 1. 按 hosts_example.csv 格式填写主机清单
# 2. 编辑 batch_ssh_setup.ps1 顶部 $CONFIG 配置区
.\batch_ssh_setup.ps1 -HostList hosts.csv -Interactive   # 逐台输密码
# 或
.\batch_ssh_setup.ps1 -HostList hosts.csv -Password 'xxx' # 全自动
```

运行后生成 `batch_ssh_setup.log`（过程日志）和 `batch_ssh_report.csv`（每台结果报告）。

**特性：**

- ✅ 幂等：已免密的主机自动跳过，公钥去重，可反复运行
- ✅ 参数全变量化：IP / 端口 / 用户名 / 密钥 / 别名均可配置
- ✅ SSH_ASKPASS 自动应答密码，密码临时文件用后立即删除
- ✅ 全程日志 + 异常捕获 + 结束暂停，告别"一闪而过"

> ⚠️ 安全说明：为免交互，脚本使用 `StrictHostKeyChecking=no`（不校验主机指纹），仅适合**可信内网**。公网环境请预先分发 `known_hosts` 并去掉该参数。

## 🛠️ 环境要求

- Windows 10/11，自带 **OpenSSH 客户端**（设置 → 应用 → 可选功能 → 添加功能）
- PowerShell 5.1+（脚本已存为 UTF-8 with BOM，避免中文乱码）
- 目标机 Linux 开启 sshd，允许密码登录（首次投递公钥时用）

## 📝 License

MIT —— 随便用，欢迎 Star 和提 Issue。
