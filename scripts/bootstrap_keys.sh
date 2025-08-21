#!/usr/bin/env bash
# scripts/bootstrap_keys.sh
#
# Ensure alias IP on CN, install sshpass (runner + CN), auto-generate key if missing,
# push pubkey to host & alias IP, and verify key-based SSH.
#
# Run examples:
#   SERVER_FILE=server_pci_map.txt ./scripts/bootstrap_keys.sh
#   ./scripts/bootstrap_keys.sh --host 172.27.28.193 --alias-ip 10.10.10.20
#
# Environment (overrides):
#   SERVER_FILE         Path to hosts file (default: server_pci_map.txt)
#   SSH_KEY             Private key path (default: /var/lib/jenkins/.ssh/jenkins_key)
#   INSTALL_IP_ADDR     CIDR for alias (e.g. 10.10.10.20/24) → alias ip auto-derived
#   CN_BOOTSTRAP_PASS   One-time root password on CN (default: root123)

set -euo pipefail

# -------- defaults --------
: "${SERVER_FILE:=server_pci_map.txt}"
: "${SSH_KEY:=/var/lib/jenkins/.ssh/jenkins_key}"
: "${CN_BOOTSTRAP_PASS:=root123}"
: "${INSTALL_IP_ADDR:=}"
SSH_USER="${SSH_USER:-root}"

TARGET_HOST=""
ALIAS_IP="${INSTALL_IP_ADDR%%/*:-}"
FORCE=0

usage() {
  cat <<EOF >&2
Usage:
  $0 [--server-file <file>] [--host <host_ip>] [--alias-ip <ip>] [--user <user>] [--pass <password>] [--key </path/to/key>] [--force]

If --host is omitted, hosts are read from SERVER_FILE (default: server_pci_map.txt).
Env overrides: SERVER_FILE, SSH_KEY, SSH_USER, INSTALL_IP_ADDR, CN_BOOTSTRAP_PASS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-file) SERVER_FILE="${2:-}"; shift 2 ;;
    --host)        TARGET_HOST="${2:-}"; shift 2 ;;
    --alias-ip)    ALIAS_IP="${2:-}"; shift 2 ;;
    --user)        SSH_USER="${2:-}"; shift 2 ;;
    --pass)        CN_BOOTSTRAP_PASS="${2:-}"; shift 2 ;;
    --key)         SSH_KEY="${2:-}"; shift 2 ;;
    --force)       FORCE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

SSH_KEY_PUB="${SSH_KEY}.pub"
SSH_BASE_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o ConnectionAttempts=1"
SSH_KEY_OPTS="-i ${SSH_KEY} ${SSH_BASE_OPTS}"

log(){ echo "[bootstrap] $*"; }

# Always suppress interactive UI for any apt/dpkg
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SVC=l
export UCF_FORCE_CONFFOLD=1

# ---------- runner helpers ----------
ensure_sshpass_on_runner() {
  if command -v sshpass >/dev/null 2>&1; then return 0; fi
  log "runner: installing sshpass (no upgrades/no popups)..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo -E apt-get install -yq --no-install-recommends --no-upgrade sshpass
  elif command -v yum >/dev/null 2>&1; then
    sudo -E yum install -y sshpass
  else
    echo "❌ runner pkg mgr not found; install sshpass manually" >&2
    exit 1
  fi
}

ensure_keypair() {
  if [[ ! -s "${SSH_KEY}" ]]; then
    log "runner: SSH private key not found → generating: ${SSH_KEY}"
    mkdir -p "$(dirname "${SSH_KEY}")"
    ssh-keygen -q -t rsa -N '' -f "${SSH_KEY}"
    chmod 600 "${SSH_KEY}"
  fi
  [[ -s "${SSH_KEY_PUB}" ]] || ssh-keygen -y -f "${SSH_KEY}" > "${SSH_KEY_PUB}"
}

key_ok() {
  local tgt="$1"
  timeout 5 ssh ${SSH_KEY_OPTS} "${SSH_USER}@${tgt}" true 2>/dev/null
}

copy_key_to() {
  local tgt="$1" pass="$2"
  ssh-keygen -q -R "${tgt}" >/dev/null 2>&1 || true
  log "ssh-copy-id → ${tgt}"
  if timeout 7 sshpass -p "$pass" ssh-copy-id \
        -i "${SSH_KEY_PUB}" \
        -o StrictHostKeyChecking=no \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o ConnectTimeout=5 -o ConnectionAttempts=1 \
        "${SSH_USER}@${tgt}" >/dev/null 2>&1; then
    return 0
  fi
  log "ssh-copy-id failed/timed out; fallback append → ${tgt}"
  timeout 7 sshpass -p "$pass" ssh \
        -o StrictHostKeyChecking=no \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o ConnectTimeout=5 -o ConnectionAttempts=1 \
        "${SSH_USER}@${tgt}" \
        "umask 077 && mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && printf '%s\n' '$(cat "${SSH_KEY_PUB}")' >> ~/.ssh/authorized_keys"
}

# ---------- remote snippets ----------
read -r -d '' ENSURE_IP_SNIPPET <<'RS' || true
set -euo pipefail
IP_CIDR="$1"; FORCE_IFACE="${2-}"
is_present(){ ip -4 addr show | awk '/inet /{print $2}' | grep -qx "$IP_CIDR"; }
echo "[IP] Ensuring ${IP_CIDR}"
if is_present; then echo "[IP] Present: ${IP_CIDR}"; exit 0; fi
declare -a CAND=()
[[ -n "$FORCE_IFACE" ]] && CAND+=("$FORCE_IFACE")
DEF_IF=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}' || true)
[[ -n "${DEF_IF:-}" ]] && CAND+=("$DEF_IF")
while IFS= read -r ifc; do CAND+=("$ifc"); done < <(
  ip -o link | awk -F': ' '{print $2}' \
    | grep -E '^(en|eth|ens|eno|em|bond|br)[0-9A-Za-z._-]+' \
    | grep -Ev '(^lo$|docker|podman|cni|flannel|cilium|calico|weave|veth|tun|tap|virbr|wg)' \
    | sort -u
)
for IF in "${CAND[@]}"; do
  [[ -z "$IF" ]] && continue
  echo "[IP] Trying ${IP_CIDR} on iface ${IF}..."
  ip link set dev "$IF" up || true
  if ip addr replace "$IP_CIDR" dev "$IF" 2>"/tmp/ip_err_${IF}.log"; then
    ip -4 addr show dev "$IF" | grep -q "$IP_CIDR" && { echo "[IP] OK on ${IF}"; exit 0; }
  fi
  echo "[IP] Failed on ${IF}: $(tr -d '\n' </tmp/ip_err_${IF}.log)" || true
done
echo "[IP] ERROR: Could not plumb ${IP_CIDR} on any iface. Candidates: ${CAND[*]}"; exit 2
RS

read -r -d '' FIX_SSHD_SNIPPET <<'RS' || true
set -euo pipefail
mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-listen-all.conf <<'EOT'
ListenAddress 0.0.0.0
EOT
cat >/etc/ssh/sshd_config.d/99-bootstrap-auth.conf <<'EOT'
PermitRootLogin yes
PasswordAuthentication yes
EOT
echo "[CN][sshd] enabling listen-all + password auth"
if sshd -t; then systemctl restart sshd || service ssh restart || true; fi
ss -ltnp | awk '$4 ~ /:22$/ {print "[CN][sshd] listening on",$4}'
RS

read -r -d '' SEND_GARP_SNIPPET <<'RS' || true
set -euo pipefail
ALIAS="$1"
IFACE="$(ip -o addr show to "$ALIAS/32" | awk '{print $2}' | head -n1 || true)"
echo "[CN][arp] announcing ${ALIAS} on iface ${IFACE:-<unknown>}"
if command -v apt-get >/dev/null 2>&1; then
  apt-get install -yq --no-install-recommends --no-upgrade iputils-arping >/dev/null 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
  yum install -y iputils >/dev/null 2>&1 || true
fi
if command -v arping >/dev/null 2>&1 && [[ -n "${IFACE:-}" ]]; then
  arping -c 3 -U -I "$IFACE" "$ALIAS" || true
else
  [[ -n "${IFACE:-}" ]] && { ip addr del "${ALIAS}/32" dev "$IFACE" 2>/dev/null || true; ip addr add "${ALIAS}/32" dev "$IFACE" || true; }
fi
RS

# Install sshpass on CN (try key path; if not, use password)
ensure_sshpass_on_cn() {
  local host="$1"
  echo "[CN][${host}] ensure sshpass..."
  if key_ok "${host}"; then
    ssh ${SSH_KEY_OPTS} "${SSH_USER}@${host}" bash -lc '
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SVC=l UCF_FORCE_CONFFOLD=1
      if command -v sshpass >/dev/null 2>&1; then echo "[CN] sshpass present"; exit 0; fi
      if command -v apt-get >/dev/null 2>&1; then
        echo "[CN] installing sshpass via apt-get (no-upgrade)"
        apt-get install -yq --no-install-recommends --no-upgrade sshpass && echo "[CN] sshpass INSTALLED"
      elif command -v yum >/dev/null 2>&1; then
        echo "[CN] installing sshpass via yum"
        yum install -y sshpass && echo "[CN] sshpass INSTALLED"
      else echo "[CN] pkg mgr not found"; fi
    ' || true
  else
    sshpass -p "${CN_BOOTSTRAP_PASS}" ssh -o StrictHostKeyChecking=no "${SSH_USER}@${host}" bash -lc '
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SVC=l UCF_FORCE_CONFFOLD=1
      if command -v sshpass >/dev/null 2>&1; then echo "[CN] sshpass present"; exit 0; fi
      if command -v apt-get >/dev/null 2>&1; then
        echo "[CN] installing sshpass via apt-get (no-upgrade)"
        apt-get install -yq --no-install-recommends --no-upgrade sshpass && echo "[CN] sshpass INSTALLED"
      elif command -v yum >/dev/null 2>&1; then
        echo "[CN] installing sshpass via yum"
        yum install -y sshpass && echo "[CN] sshpass INSTALLED"
      else echo "[CN] pkg mgr not found"; fi
    ' || true
  fi
}

# ---------- per-host procedure ----------
handle_host() {
  local host="$1"
  echo; echo "─── Host ${host} ───────────────────────────────────────"

  # 1) Ensure alias IP first (before auth attempts)
  if [[ -n "${INSTALL_IP_ADDR:-}" ]]; then
    ssh ${SSH_KEY_OPTS} "${SSH_USER}@${host}" bash -s -- "${INSTALL_IP_ADDR}" "" <<<"${ENSURE_IP_SNIPPET}" || \
      { echo "[bootstrap][${host}] ⚠️ ensure ${INSTALL_IP_ADDR} failed (continuing)"; }
  fi

  # 2) Make sure CN has sshpass (for our fallbacks if needed)
  ensure_sshpass_on_cn "${host}" || true

  # 3) Ensure sshd listens/permits password (for bootstrap)
  ssh ${SSH_KEY_OPTS} "${SSH_USER}@${host}" bash -s <<<"${FIX_SSHD_SNIPPET}" || true

  # 3b) Announce alias ARP (helps if alias is new)
  if [[ -n "${ALIAS_IP:-}" ]]; then
    ssh ${SSH_KEY_OPTS} "${SSH_USER}@${host}" bash -s -- "${ALIAS_IP}" <<<"${SEND_GARP_SNIPPET}" || true
  fi

  # 4) Push key to host IP
  if (( FORCE )) || ! key_ok "${host}"; then
    copy_key_to "${host}" "${CN_BOOTSTRAP_PASS}" || true
  fi
  if key_ok "${host}"; then
    echo "[bootstrap][${host}] ✅ key OK (host IP)"
  else
    echo "[bootstrap][${host}] ❌ key failing (host IP)"
  fi

  # 5) Try alias IP (if reachable quickly) — avoid long pipeline stalls
  if [[ -n "${ALIAS_IP:-}" ]]; then
    if timeout 3 bash -lc "</dev/tcp/${ALIAS_IP}/22" 2>/dev/null; then
      if (( FORCE )) || ! key_ok "${ALIAS_IP}"; then
        copy_key_to "${ALIAS_IP}" "${CN_BOOTSTRAP_PASS}" || true
      fi
      if key_ok "${ALIAS_IP}"; then
        echo "[bootstrap][${host}] ✅ key OK (alias ${ALIAS_IP})"
      else
        echo "[bootstrap][${host}] ❌ key failing (alias ${ALIAS_IP})"
      fi
    else
      echo "[bootstrap][${host}] ⚠️ alias ${ALIAS_IP}:22 not reachable from runner; skipping alias copy"
    fi
  fi
}

main() {
  ensure_sshpass_on_runner
  ensure_keypair

  if [[ -n "${TARGET_HOST:-}" ]]; then
    handle_host "${TARGET_HOST}"
    exit 0
  fi

  [[ -f "${SERVER_FILE}" ]] || { echo "❌ SERVER_FILE not found: ${SERVER_FILE}"; exit 2; }
  mapfile -t HOSTS < <(awk 'NF && $1 !~ /^#/ {
    if (index($0,":")>0) { n=split($0,a,":"); print a[2] } else { print $1 }
  }' "${SERVER_FILE}")

  ((${#HOSTS[@]})) || { echo "❌ No hosts parsed from ${SERVER_FILE}"; exit 2; }

  echo "[bootstrap] Hosts: ${HOSTS[*]}"
  [[ -n "${ALIAS_IP:-}" ]] && echo "[bootstrap] Alias IP: ${ALIAS_IP} (from ${INSTALL_IP_ADDR})" || echo "[bootstrap] Alias IP: <none>"

  for h in "${HOSTS[@]}"; do
    handle_host "${h}"
  done
}
main
