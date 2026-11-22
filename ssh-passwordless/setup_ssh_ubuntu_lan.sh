#!/usr/bin/env bash
# ============================================================
# 配置本机 → Ubuntu 目标机 (192.168.1.10) 的 SSH 免密登录
# 适用环境：Windows Git Bash / macOS / Linux 作为客户端
# 用法：1) 把 TARGET_USER 改成目标机实际用户名
#      2) 整段复制到 Git Bash 执行（首次会提示输入目标机密码）
# 特性：幂等、不覆盖已有密钥、公钥去重、带错误检查
# ============================================================

set -euo pipefail

# ---------- 配置区（只需改 TARGET_USER）----------
TARGET_HOST="192.168.1.10"   # 目标机 IP
TARGET_USER="ubuntu"          # ← 改成你的 Ubuntu 用户名，例如 root / ops
SSH_PORT="22"
KEY_NAME="id_ed25519_lan_10"  # 专用密钥名，避免覆盖你已有的 id_rsa / id_ed25519
ALIAS="ubuntu-lan"            # 配好后可直接 ssh ubuntu-lan
# ------------------------------------------------

KEY="$HOME/.ssh/$KEY_NAME"
PUB="$KEY.pub"

log() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# 0) 准备本机 .ssh 目录
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# 1) 幂等生成 ed25519 密钥对（已存在则复用，绝不覆盖）
if [[ ! -f "$KEY" || ! -f "$PUB" ]]; then
  [[ -f "$KEY" || -f "$PUB" ]] && die "检测到残缺密钥文件 $KEY，请手动删除后重试"
  ssh-keygen -t ed25519 -N '' -C "lan-${TARGET_HOST}-$(date +%F)" -f "$KEY" >/dev/null
  chmod 600 "$KEY"
  chmod 644 "$PUB"
  log "密钥已生成：$KEY"
else
  log "复用已有密钥：$KEY"
fi

# 2) 端口连通性预检（本机有 nc 时）
if command -v nc >/dev/null 2>&1; then
  nc -z -w 3 "$TARGET_HOST" "$SSH_PORT" || die "端口 ${TARGET_HOST}:${SSH_PORT} 不通，检查网络/防火墙/sshd"
  log "目标机 ${TARGET_HOST}:${SSH_PORT} 可达"
fi

# 3) 投递公钥：先去重检查，未存在才追加（可重复执行）
# 首次需要输入目标机密码；StrictHostKeyChecking=accept-new 自动接受首次主机指纹
if ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "$TARGET_USER@$TARGET_HOST" \
   "grep -qxF '$(cat "$PUB")' ~/.ssh/authorized_keys 2>/dev/null"; then
  log "公钥已在目标机 authorized_keys 中，跳过投递"
else
  ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "$TARGET_USER@$TARGET_HOST" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
    < "$PUB" || die "公钥投递失败：请检查用户名、密码、目标机 sshd 是否运行"
  log "公钥已写入目标机 authorized_keys"
fi

# 4) 免密验证：BatchMode=yes 禁止交互输密码，能返回 LOGIN_OK 即成功
ssh -p "$SSH_PORT" -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 \
  "$TARGET_USER@$TARGET_HOST" 'echo LOGIN_OK; hostname; whoami' \
  || die "免密验证失败，请按文末排错表排查"

# 5) 写入 ssh config 别名（幂等，避免重复追加）
if ! grep -q "^Host ${ALIAS}$" "$HOME/.ssh/config" 2>/dev/null; then
  cat >> "$HOME/.ssh/config" <<EOF

Host $ALIAS
    HostName $TARGET_HOST
    Port $SSH_PORT
    User $TARGET_USER
    IdentityFile ~/.ssh/$KEY_NAME
    IdentitiesOnly yes
    ServerAliveInterval 60
EOF
fi
chmod 600 "$HOME/.ssh/config"
log "全部完成！以后直接执行： ssh $ALIAS"
