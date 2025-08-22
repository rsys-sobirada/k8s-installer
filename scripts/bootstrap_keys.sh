#!/usr/bin/env bash
set -euo pipefail

# --- Get IP (accept env IP, first positional arg, or --alias-ip flag) ---
IP="${IP:-${1:-}}"
if [[ -z "${IP}" && $# -gt 0 ]]; then
  # very small flag parser (only what we need)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --alias-ip) IP="${2:-}"; shift 2 ;;
      --host|--pass|--key) shift 2 ;;  # ignore
      --*) shift ;;                     # ignore other flags
      *) shift ;;                       # ignore stray arg
    esac
  done
fi
IP="${IP%%/*}"                     # strip mask if present
: "${IP:?IP required (e.g. 10.10.10.20)}"

# --- Your exact actions, with one safety: don't re-generate if key exists ---
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[[ -s ~/.ssh/id_rsa ]] || ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa
ssh-copy-id root@"${IP}"
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
ssh-keygen -f "/root/.ssh/known_hosts" -R "${IP}" || true
systemctl restart sshd
