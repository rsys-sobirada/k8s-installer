#!/usr/bin/env bash
set -euo pipefail

# ---- Resolve IP ----
# Accept from env IP, or parse --alias-ip, or 1st positional arg (in that order)
IP="${IP:-${1:-}}"
if [[ -z "${IP}" && $# -gt 0 ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --alias-ip) IP="${2:-}"; shift 2 ;;
      --host|--pass|--key|--force) shift 2 || true ;;  # ignore these flags/values if present
      --*) shift ;;                                     # ignore other flags
      *) shift ;;                                       # ignore stray args
    esac
  done
fi

# Strip CIDR mask if present, remove quotes/CR/LF and trim spaces
IP="${IP%%/*}"
IP="$(printf '%s' "$IP" | tr -d '\r\n\"' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"

# Validate basic IPv4 format
if ! [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "ERROR: IP is empty or malformed after sanitization: '$(printf %q "$IP")'" >&2
  exit 2
fi

# ---- Your requested operations (unchanged in spirit) ----
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[[ -s ~/.ssh/id_rsa ]] || ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa
ssh-copy-id root@"${IP}"
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
ssh-keygen -f "/root/.ssh/known_hosts" -R "${IP}" || true
systemctl restart sshd
