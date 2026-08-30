#!/usr/bin/env bash
set -euo pipefail

# SSH 免密配置脚本（无需 Ansible）
# - 从 inventory.ini ([gpu_nodes:vars]) 读取 ansible_user/ansible_password
# - 从 [gpu_nodes] 读取主机列表
# - 跳过 ansible_connection=local 的主机
# - 生成本机 SSH 密钥（如不存在），并分发公钥到远程主机实现免密登录
#
# 用法：
#   ./ssh-setup.sh            # 执行免密配置
#   ./ssh-setup.sh --list     # 仅列出清单中的主机
#   ./ssh-setup.sh --check    # 仅检查免密是否已生效（不分发密钥）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INV_FILE="${INV_FILE:-$SCRIPT_DIR/inventory.ini}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"

usage() {
  cat <<'EOF'
用法：
  ./ssh-setup.sh            # 生成密钥并分发到远程主机，实现免密登录
  ./ssh-setup.sh --list     # 仅列出清单中的主机
  ./ssh-setup.sh --check    # 仅检查免密登录是否已生效（不分发密钥）

凭据读取规则：
  优先使用主机级 ansible_user/ansible_password（各主机密码不同时在主机行单独指定），
  未指定时回退到 [gpu_nodes:vars] 组级配置。

环境变量覆盖：
  INV_FILE=./inventory.ini   指定清单文件
  ANSIBLE_USER=...           覆盖组级用户名
  ANSIBLE_PASSWORD=...       覆盖组级密码
  SSH_KEY=~/.ssh/id_rsa      指定密钥路径
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: 缺少命令: $1" >&2; exit 1; }
}

# 从 [gpu_nodes:vars] 段读取变量值
get_group_var() {
  local key="$1"
  awk -F= -v k="$key" '
    BEGIN{invars=0}
    /^\[gpu_nodes:vars\]/{invars=1; next}
    /^\[/{if(invars==1){exit}}
    invars==1 && $0 !~ /^[[:space:]]*#/ && $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
      v=$2
      sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      print v; exit
    }
  ' "$INV_FILE"
}

# 从 [gpu_nodes] 段解析主机列表
# 输出格式：主机别名|实际IP或主机名|是否local(0/1)|主机级用户(可空)|主机级密码(可空)
# 支持主机级 ansible_user / ansible_password 覆盖组级配置（各主机密码不同时使用）
# 注意：使用 | 作为分隔符（tab 会被 read 合并空字段导致错位）
inventory_hosts() {
  awk '
    /^\[gpu_nodes\]/{in_section=1; next}
    /^\[/{ if(in_section==1){ exit } }
    in_section==1 && $0 !~ /^[[:space:]]*($|#)/ {
      line=$0
      split($0, a, " ")
      name=a[1]
      host=name
      if (match(line, /ansible_host=([^[:space:]]+)/, m)) host=m[1]
      localconn=0
      if (line ~ /ansible_connection=local/) localconn=1
      huser=""
      if (match(line, /ansible_user=([^[:space:]]+)/, m)) huser=m[1]
      hpass=""
      if (match(line, /ansible_password=([^[:space:]]+)/, m)) hpass=m[1]
      print name "|" host "|" localconn "|" huser "|" hpass
    }
  ' "$INV_FILE"
}

# TCP 22 端口连通性检测
tcp22_check() {
  local host="$1"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 5 "$host" 22 >/dev/null 2>&1
  else
    timeout 5 bash -c "cat < /dev/null > /dev/tcp/${host}/22" >/dev/null 2>&1
  fi
}

# 生成 SSH 密钥对（如不存在）
ensure_ssh_key() {
  if [[ -f "$SSH_KEY" ]]; then
    echo "INFO: SSH 密钥已存在: $SSH_KEY"
  else
    echo "INFO: 生成 SSH 密钥: $SSH_KEY"
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -q
    echo "INFO: 密钥生成完成"
  fi
}

# 使用密码分发公钥到远程主机（幂等：已存在则不重复追加）
distribute_key() {
  local user="$1" host="$2" pass="$3"
  local pubkey
  pubkey=$(cat "${SSH_KEY}.pub")
  SSHPASS="$pass" sshpass -e ssh -n \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o ConnectTimeout=10 \
    "${user}@${host}" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '${pubkey}' ~/.ssh/authorized_keys || echo '${pubkey}' >> ~/.ssh/authorized_keys"
}

# 验证免密登录是否生效（不使用密码）
check_passwordless() {
  local user="$1" host="$2"
  ssh -n -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    "${user}@${host}" 'echo ok' >/dev/null 2>&1
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage; exit 0
  fi

  if [[ ! -f "$INV_FILE" ]]; then
    echo "ERROR: 清单文件不存在: $INV_FILE" >&2; exit 2
  fi

  # --list 模式：仅列出主机
  if [[ "${1:-}" == "--list" ]]; then
    printf "%-12s %-18s %-8s %s\n" "别名" "地址" "类型" "主机级用户"
    while IFS='|' read -r name host localconn huser hpass; do
      [[ -z "${name:-}" ]] && continue
      printf "%-12s %-18s %-8s %s\n" "$name" "$host" \
        "$([[ "$localconn" == "1" ]] && echo "(local)" || echo "(remote)")" \
        "${huser:-（用组级）}"
    done < <(inventory_hosts)
    exit 0
  fi

  need_cmd sshpass
  need_cmd ssh
  need_cmd ssh-keygen
  need_cmd timeout

  # 组级用户/密码作为默认值（可被主机级 ansible_user/ansible_password 覆盖）
  local group_user="${ANSIBLE_USER:-$(get_group_var ansible_user)}"
  local group_pass="${ANSIBLE_PASSWORD:-$(get_group_var ansible_password)}"
  if [[ -z "${group_user:-}" ]]; then
    echo "ERROR: 无法从 $INV_FILE 读取 ansible_user（组级或主机级）" >&2
    exit 3
  fi

  # --check 模式：仅验证免密是否已生效
  if [[ "${1:-}" == "--check" ]]; then
    echo "== 免密登录检查 (清单: $INV_FILE) =="
    local failures=0
    while IFS='|' read -r name host localconn huser hpass; do
      [[ -z "${name:-}" ]] && continue
      if [[ "$localconn" == "1" ]]; then
        echo "-- $name (local) -- 跳过"
        continue
      fi
      local user="${huser:-$group_user}"
      if check_passwordless "$user" "$host"; then
        echo "-- $name ($host) -- 免密登录正常"
      else
        echo "-- $name ($host) -- 免密登录失败" >&2
        failures=$((failures+1))
      fi
    done < <(inventory_hosts)
    [[ "$failures" -gt 0 ]] && { echo "ERROR: $failures 台主机免密未生效" >&2; exit 10; }
    echo "OK: 所有主机免密登录正常"
    exit 0
  fi

  # 默认模式：生成密钥 + 分发 + 验证
  echo "== SSH 免密配置 (清单: $INV_FILE) =="
  ensure_ssh_key

  local failures=0
  while IFS='|' read -r name host localconn huser hpass; do
    [[ -z "${name:-}" ]] && continue
    if [[ "$localconn" == "1" ]]; then
      echo "-- $name (local) -- 跳过"
      continue
    fi

    # 主机级凭据优先，回退到组级
    local user="${huser:-$group_user}"
    local pass="${hpass:-$group_pass}"

    echo "-- $name ($host) --"

    # 先检查是否已免密
    if check_passwordless "$user" "$host"; then
      echo "   已免密，跳过分发"
      continue
    fi

    # 无可用密码时无法分发
    if [[ -z "$pass" ]]; then
      echo "   FAILED: 未配置该主机的密码（主机级或组级 ansible_password 均为空）" >&2
      failures=$((failures+1))
      continue
    fi

    # 检测端口连通
    if ! tcp22_check "$host"; then
      echo "   FAILED: TCP/22 不可达: $name ($host)" >&2
      failures=$((failures+1))
      continue
    fi

    # 分发公钥
    echo "   分发公钥..."
    if distribute_key "$user" "$host" "$pass"; then
      echo "   公钥分发成功"
    else
      echo "   FAILED: 公钥分发失败: $name ($host)" >&2
      failures=$((failures+1))
      continue
    fi

    # 验证免密
    if check_passwordless "$user" "$host"; then
      echo "   免密验证通过"
    else
      echo "   FAILED: 分发后免密验证失败: $name ($host)" >&2
      failures=$((failures+1))
    fi
  done < <(inventory_hosts)

  if [[ "$failures" -gt 0 ]]; then
    echo "ERROR: $failures 台主机配置失败" >&2
    exit 10
  fi

  echo "OK: 所有主机 SSH 免密配置完成"
}

main "$@"
