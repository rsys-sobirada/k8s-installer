#!/usr/bin/env bash
set -euo pipefail
# Re-assert alias IP just before doing work
HOSTS=$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){n=split($0,a,":"); print a[2]} else {print $1} }' "${SERVER_FILE}" | paste -sd " " -)
for h in ${HOSTS}; do
  ensure_alias_ip "$h"
done

# Resolve IP the same way you’ve been passing it
IP="${IP:-}"
if [[ -z "${IP}" && $# -gt 0 ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --alias-ip) IP="${2:-}"; shift 2 ;;
      --host|--pass|--key) shift 2 ;;
      --force) shift ;;
      --*) shift ;;
      *) shift ;;
    esac
  done
fi
IP="${IP%%/*}"
if ! [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "ERROR: IP is empty or malformed: '$IP'" >&2
  exit 2
fi

# --- your requested sequence, with tiny hardening for host key ---
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[[ -s ~/.ssh/id_rsa ]] || ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa

# NEW: clear any stale key and pre-seed the current one to avoid the popup
ssh-keygen -f "/root/.ssh/known_hosts" -R "${IP}" >/dev/null 2>&1 || true
ssh-keyscan -H "${IP}" >> /root/.ssh/known_hosts 2>/dev/null || true

# Add -o StrictHostKeyChecking=no to bypass interactivity on first contact
ssh-copy-id -o StrictHostKeyChecking=no root@"${IP}"

cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
ssh-keygen -f "/root/.ssh/known_hosts" -R "${IP}" >/dev/null 2>&1 || true
systemctl restart sshd
