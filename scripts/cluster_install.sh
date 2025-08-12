#!/bin/bash
# Per-server install:
# - Ensure 10.10.10.20/24 exists (iface may remain DOWN)
# - Build NEW path from NEW_* + K8S_VER
# - yes yes | ./install_k8s.sh

set -euo pipefail

# ---- tiny helpers (local only) ----
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
: "${INSTALL_SERVER_FILE:=server_pci_map.txt}"   # CSV: server,pci
: "${INSTALL_IP_ADDR:=10.10.10.20/24}"
: "${INSTALL_IP_IFACE:=}"                    # optional: force iface name

NEW_VER_PATH="$(normalize_k8s_path "$NEW_BUILD_PATH" "$NEW_VERSION" "$K8S_VER" "$REL_SUFFIX")"

echo "NEW_VERSION:      $NEW_VERSION"
echo "NEW_BUILD_PATH:   $NEW_BUILD_PATH"
echo "NEW_VER_PATH:     $NEW_VER_PATH"
echo "INSTALL_LIST:     $INSTALL_SERVER_FILE"
echo "IP to ensure:     $INSTALL_IP_ADDR"
[[ -n "$INSTALL_IP_IFACE" ]] && echo "Forced iface:    $INSTALL_IP_IFACE"
echo "────────────────────────────────────────"

[[ -f "$INSTALL_SERVER_FILE" ]] || { echo "❌ Missing $INSTALL_SERVER_FILE"; exit 1; }

# ---- remote snippets (run on target host via SSH) ----

# $1=IP/CIDR, $2=forced_iface_or_empty
read -r -d '' ensure_ip_snippet <<'RSCRIPT' || true
set -euo pipefail
IP_CIDR="$1"; FORCE_IFACE="${2-}"
# present?
if ip -4 addr show | grep -q -E "[[:space:]]${IP_CIDR%/*}(/|[[:space:]])"; then
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
read -r -d '' run_install_snippet <<'RSCRIPT' || true
set -euo pipefail
P="$1"
cd "$P" || { echo "[ERROR] Path not found: $P"; exit 2; }
sed -i 's/\r$//' install_k8s.sh 2>/dev/null || true
echo "[RUN] yes yes | ./install_k8s.sh (in $P)"
yes yes | bash ./install_k8s.sh
RSCRIPT

# ---- iterate servers CSV "server,pci" ----
while IFS=, read -r server pci || [[ -n "${server:-}" ]]; do
  server="$(echo -n "${server:-}" | tr -d '\r\t ')"
  [[ -z "$server" || "${server:0:1}" == "#" ]] && continue

  echo ""
  echo "🧩 Server: $server"
  echo "📁 Path:   $NEW_VER_PATH"

  # 1) Ensure IP exists (iface may remain DOWN)
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$server" \
      bash -s -- "$INSTALL_IP_ADDR" "$INSTALL_IP_IFACE" <<<"$ensure_ip_snippet"

  # 2) Run installer
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$server" \
      bash -s -- "$NEW_VER_PATH" <<<"$run_install_snippet"

  echo "✅ Install triggered on $server"
done < "$INSTALL_SERVER_FILE"

echo ""
echo "🎉 Install step completed (installer invoked on all servers)."
