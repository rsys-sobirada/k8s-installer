#!/bin/bash
# scripts/cluster_install.sh
# Per-server install:
# - Ensure 10.10.10.20/24 exists (iface may remain DOWN)
# - Build NEW path using normalize_k8s_path
# - yes yes | ./install_k8s.sh

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

# ---- Inputs from Jenkins ----
require NEW_VERSION   "6.3.0_EA2"
require NEW_BUILD_PATH "/home/labadmin"
: "${K8S_VER:=1.31.4}"
: "${KSPRAY_DIR:=kubespray-2.27.0}"
: "${REL_SUFFIX:=}"                         # usually empty
: "${SSH_KEY:=/var/lib/jenkins/.ssh/jenkins_key}"
: "${INSTALL_SERVER_FILE:=server_pci_map.txt}"
: "${INSTALL_IP_ADDR:=10.10.10.20/24}"     # required address; can change later if needed

NEW_VER_PATH="$(normalize_k8s_path "$NEW_BUILD_PATH" "$NEW_VERSION" "$K8S_VER" "$REL_SUFFIX")"

echo "NEW_VERSION:      $NEW_VERSION"
echo "NEW_BUILD_PATH:   $NEW_BUILD_PATH"
echo "NEW_VER_PATH:     $NEW_VER_PATH"
echo "INSTALL_LIST:     $INSTALL_SERVER_FILE"
echo "KSPRAY_DIR:       $KSPRAY_DIR"
echo "IP to ensure:     $INSTALL_IP_ADDR"
echo "────────────────────────────────────────"

[[ -f "$INSTALL_SERVER_FILE" ]] || { echo "❌ Missing $INSTALL_SERVER_FILE"; exit 1; }

pick_iface_snippet='
set -euo pipefail
NEED_IP="$1"
have_ip() { ip -4 addr show | grep -q -E "[[:space:]]'"'"'${NEED_IP%/*}'"'"'(/|[[:space:]])" ; }
if have_ip; then
  echo "[IP] Present: ${NEED_IP}"
else
  IFACE=""
  if command -v lshw >/dev/null 2>&1; then
    IFACE="$(lshw -quiet -c network -businfo 2>/dev/null | awk "NR>2 && \$2 != \"\" {print \$2}" | grep -E "^(en|eth|ens|eno|em|bond)[0-9]" | head -n1 || true)"
  fi
  if [[ -z "${IFACE}" ]]; then
    IFACE="$(ip -o link | awk -F\": \" "{print \$2}" | grep -E "^(en|eth|ens|eno|em|bond)" | head -n1 || true)"
  fi
  if [[ -z "${IFACE}" ]]; then
    echo "[WARN] No suitable iface found; falling back to lo"
    IFACE="lo"
  fi
  ip addr replace '"${INSTALL_IP_ADDR}"' dev "${IFACE}" || true
  echo "[IP] Plumbed '"${INSTALL_IP_ADDR}"' on ${IFACE} (iface may remain DOWN)"
fi
'

install_snippet='
set -euo pipefail
PTH="$1"
cd "$PTH" || { echo "[ERROR] path missing: $PTH"; exit 2; }
sed -i "s/\r$//" install_k8s.sh 2>/dev/null || true
echo "[RUN] yes yes | ./install_k8s.sh (in $PTH)"
yes yes | bash ./install_k8s.sh
'

# ---- Iterate servers from CSV "server,pci" (we use first column as host) ----
while IFS=, read -r server pci || [[ -n "${server:-}" ]]; do
  server="$(echo -n "${server:-}" | tr -d '\r\t ')"
  [[ -z "$server" || "${server:0:1}" == "#" ]] && continue

  echo ""
  echo "🧩 Server: $server"
  echo "📁 Path:   $NEW_VER_PATH"

  # 1) Ensure IP exists
  ssh_do "$server" bash -lc "$pick_iface_snippet" _ "$INSTALL_IP_ADDR"

  # 2) Run installer with auto-confirm
  ssh_do "$server" bash -lc "$install_snippet" _ "$NEW_VER_PATH"

  echo "✅ Install triggered on $server"
done < "$INSTALL_SERVER_FILE"

echo ""
echo "🎉 Install step completed (scripts invoked on all servers)."
