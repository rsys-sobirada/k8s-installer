#!/usr/bin/env bash
set -euo pipefail

# ---------- Resolve IP ----------
# Prefer env IP; else accept --alias-ip <ip>; ignore other flags.
IP="${IP:-}"
if [[ -z "${IP}" && $# -gt 0 ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --alias-ip) IP="${2:-}"; shift 2 ;;
      --host|--pass|--key) shift 2 ;;   # ignore these flags + their values
      --force) shift ;;                 # ignore flag without value
      --*) shift ;;                     # ignore unknown flags
      *) shift ;;                       # ignore stray args
    esac
  done
fi

# Strip CIDR mask and sanitize (trim/strip CR/LF/quotes)
IP="${IP%%/*}"
IP="$(printf '%s' "$IP" | tr -d '\r\n\"' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"

# Validate IPv4
if ! [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "ERROR: IP is empty or malformed after sanitization: '$(printf %q "$IP")'" >&2
  exit 2
fi

# ---------- Your requested lines (with non-interactive keygen guard) ----------
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[[ -s ~/.ssh/id_rsa ]] || ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa
ssh-copy-id root@"${IP}"
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
ssh-keygen -f "/root/.ssh/known_hosts" -R "${IP}" || true
systemctl restart sshd
