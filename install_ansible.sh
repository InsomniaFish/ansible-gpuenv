#!/usr/bin/env bash
set -euo pipefail

# Install Ansible on Debian/Ubuntu (non-interactive).
# Also installs sshpass which is useful when inventory uses ansible_password.

export DEBIAN_FRONTEND=noninteractive

usage() {
  cat <<'EOF'
Usage:
  install_ansible.sh

What it does:
  - apt-get update
  - apt-get install -y ansible sshpass
  - prints ansible --version
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: please run as root (or use sudo)." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "ERROR: apt-get not found. This script supports Debian/Ubuntu via apt." >&2
  exit 2
fi

echo "== Installing Ansible via apt =="
apt-get update -y
apt-get install -y ansible sshpass

echo
echo "== Ansible version =="
ansible --version


