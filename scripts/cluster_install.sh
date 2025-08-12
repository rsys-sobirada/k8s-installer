#!/bin/bash
# scripts/cluster_install.sh
# Install orchestrator (sequential per server)
# - Accepts server list lines in CSV "server,pci" OR colon "name:ip[:path]"
# - Ensures 10.10.10.20/24 is present (iface may remain DOWN)
# - Builds NEW path from NEW_* and runs "yes yes | ./install_k8s.sh"

set -euo pipefail

# ---- tiny helpers ----
require(){ local n="$1" ex="$2"; [[ -n "${!n:-}" ]] || { echo "❌ Missing $n (e.g. $ex)"; exit 1; }; }
ver_num(){ echo "${1%%_*}"; }   # 6.3.0_EA2 -> 6.3.0
ver_tag(){ echo "${1##*_}"; }   # 6.3.0_EA2 -> EA2
normalize_k8s_path(){ # <BASE> <VERSION> <K8S_VER> [REL_SUFFIX]
  local base="${1%/}" ver="$2" kver="$3" rel="${4-}"
  local num tag; num="$(ver_num "$ver")"; tag="$(ver_tag "$ver")"
  echo "$base/${num}/${tag}/TRILLIUM_5GCN_CNF_REL_${num}${rel}/common/tools/install/k8s-v${kver}"
}

# ---- inputs from Jenkins / env ----
require NEW_VERSION     "6.3.0_EA2"
require NEW_BUILD_PATH  "/home/labadmin"
: "${K8S_VER:=1.31.4}"
: "${REL_SUFFIX:=}"                          # usually empty
: "${SSH_KEY:=/var/lib/jenkins/.ssh/jenkins_key}"
: "${INSTALL_SERVER_FILE:=server_pci_map.txt}"   # CSV (server,pci) or colon (name:ip[:path])
: "${INSTALL_IP_ADDR:=10.10.10.20/24}"      # the address to ensure
: "${INSTALL_IP_IFACE:=}"                   # optional: force iface (e.g., enp1s0)

[[ -f "$SSH_KEY" ]] || { echo "❌ SSH key not found: $SSH_KEY"; exit 1; }
chmod 600 "$SSH_KEY" || true
[[ -f "$INSTALL_SERVER_FILE" ]] || { echo "❌ Missing $INSTALL_SERVER_FILE"; exit 1; }

NEW_VER_PATH="$(normalize_k8s_path "$NEW_BUILD_PATH" "$NEW_VERSION" "$K8S_VER" "$REL_SUFFIX")"

# SSH speed-ups (connection reuse)
SSH_OPTS='-o BatchMode=yes -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=5m -o ControlPath=/tmp/ssh_mux_%h_%p_%r'

echo "NEW_VERSION:      $NEW_VERSION"
echo "NEW_BUILD_PATH:   $NEW_BUILD_PATH"
echo "NEW_VER_PATH:     $NEW_VER_PATH"
echo "INSTALL_LIST:     $INSTALL_SERVER_FILE"
echo "IP to ensure:     $INSTALL_IP_ADDR"
[[ -n "$INSTALL_IP_IFACE" ]] && echo "Forced iface:    $INSTALL_IP_IFACE"
echo "────────────────────────────────────────"

# ---- remote snippets ----

# $1=IP/CIDR, $2=forced_iface_or_empty
read -r -d '' ENSURE_IP_SNIPPET <<'RSCRIPT' || true
set -euo pipefail
IP_CIDR="$1"; FORCE_IFACE="${2-}"

present() { ip -4 addr show | grep -q -E "[[:space:]]${IP_CIDR%/*}(/|[[:space:]])"; }

if present; then
  echo "[IP] Present: ${IP_CIDR}"
  exit 0
fi

IFACE="$FORCE_IFACE"
if [[ -z "$IFACE" ]]; then
  if command -v lshw >/dev/null 2>&1; then
    IFACE="$(lshw -quiet -c network -businfo 2>/dev/null | awk 'NR>2 && $2 != "" {print $2}' \
             | grep -E "^(en|eth|ens|eno|em|bond)[0-9]+" | head -n1 || true)"
  fi
  if [[ -z "$IFACE" ]]; then
    IFACE="$(ip -o link | awk -F': ' '{print $2}' | grep -E "^(en|eth|ens|eno|em|bond)" | head -n1 || true)"
  fi
  [[ -z "$IFACE" ]] && IFACE="lo"
fi

ip addr replace "$IP_CIDR" dev "$IFACE" || true
echo "[IP] Plumbed $IP_CIDR on ${IFACE} (iface may remain DOWN)"
RSCRIPT

# $1=install_path
read -r -d '' RUN_INSTALL_SNIPPET <<'RSCRIPT' || true
set -euo pipefail
P="$1"
cd "$P" || { echo "[ERROR] Path not found: $P"; exit 2; }
sed -i 's/\r$//' install_k8s.sh 2>/dev/null || true
echo "[RUN] yes yes | ./install_k8s.sh (in $P)"
yes yes | bash ./install_k8s.sh
RSCRIPT

any_failed=0

# ---- iterate servers: supports CSV "server,pci" or colon "name:ip[:path]" ----
while IFS= read -r raw || [[ -n "${raw:-}" ]]; do
  line="$(echo -n "${raw:-}" | tr -d '\r')"
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

  host=""
  if [[ "$line" == *,* ]]; then
    # CSV
    IFS=',' read -r server pci <<<"$line"
    host="$(echo -n "${server:-}" | xargs)"
  elif [[ "$line" == *:* ]]; then
    # Colon
    IFS=':' read -r name ip maybe_path <<<"$line"
    host="$(echo -n "${ip:-}" | xargs)"
  else
    # Single token
    host="$(echo -n "$line" | xargs)"
  fi

  if [[ -z "$host" ]]; then
    echo "⚠️  Skipping malformed line: $line"
    continue
  fi

  echo ""
  echo "🧩 Host:  $host"
  echo "📁 Path:  $NEW_VER_PATH"

  # 1) Ensure IP exists
  if ! ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$INSTALL_IP_ADDR" "$INSTALL_IP_IFACE" <<<"$ENSURE_IP_SNIPPET"; then
    echo "❌ Failed to ensure $INSTALL_IP_ADDR on $host"
    any_failed=1
    continue
  fi

  # 2) Run installer with auto-confirm
  if ! ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$NEW_VER_PATH" <<<"$RUN_INSTALL_SNIPPET"; then
    echo "❌ install_k8s.sh failed on $host"
    any_failed=1
    continue
  fi

  echo "✅ Install triggered on $host"
done < "$INSTALL_SERVER_FILE"

echo ""
if [[ $any_failed -ne 0 ]]; then
  echo "❌ One or more installs failed."
  exit 1
fi
echo "🎉 Install step completed (installer invoked on all hosts)."
