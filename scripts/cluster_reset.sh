#!/usr/bin/env bash
set -euo pipefail

# Required envs passed by Jenkins
: "${CLUSTER_RESET:?missing}"
: "${OLD_VERSION:?missing}"         # e.g. 6.3.0_EA2 or 6.3.0
: "${OLD_BUILD_PATH:?missing}"      # e.g. /home/labadmin
: "${K8S_VER:?missing}"             # e.g. 1.31.4
: "${KSPRAY_DIR:?missing}"          # e.g. kubespray-2.27.0
: "${RESET_YML_WS:?missing}"
: "${SSH_KEY:?missing}"
: "${SERVER_FILE:?missing}"
: "${REQ_WAIT_SECS:?missing}"       # e.g. 360
: "${RETRY_COUNT:?missing}"         # e.g. 3
: "${RETRY_DELAY_SECS:?missing}"    # e.g. 10

log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }
die() { log "ERROR: $*"; exit 1; }

# -------------------------------
# Build path strictly from inputs
# -------------------------------
build_reset_root_from_inputs() {
  # OLD_VERSION can be like "6.3.0_EA2" or "6.3.0"
  local old_ver="$1"       # OLD_VERSION
  local base_dir="$2"      # OLD_BUILD_PATH
  local k8s_ver="$3"       # K8S_VER

  local ver tag base reset_root
  if [[ "$old_ver" == *_* ]]; then
    ver="${old_ver%%_*}"   # 6.3.0
    tag="${old_ver#*_}"    # EA2
  else
    ver="$old_ver"         # 6.3.0
    tag=""
  fi

  base="${base_dir%/}/${ver}"
  [[ -n "$tag" ]] && base="${base}/${tag}"

  # Example:
  # /home/labadmin/6.3.0/EA2/TRILLIUM_5GCN_CNF_REL_6.3.0/common/tools/install/k8s-v1.31.4
  reset_root="${base}/TRILLIUM_5GCN_CNF_REL_${ver}/common/tools/install/k8s-v${k8s_ver}"
  printf '%s' "$reset_root"
}

# ---------------------------------------------
# Read hosts only (ignore any mapped path part)
# server_pci_map.txt can be:
#   name:ip:/some/old/path
# or
#   ip
# or
#   name ip
# ---------------------------------------------
read_targets() {
  awk '
    NF && $1 !~ /^#/ {
      # If line has colon-separated fields name:ip[:path], pick the 2nd as IP
      if (index($0,":")>0) {
        n=split($0, a, ":");
        if (n>=2) print a[2];
        else      print a[1];
      } else {
        # Otherwise, first whitespace field is the host/IP
        print $1;
      }
    }
  ' "$SERVER_FILE"
}

# -------------------------
# Work on a single host/IP
# -------------------------
reset_on_host() {
  local host_ip="$1"

  local reset_root
  reset_root="$(build_reset_root_from_inputs "$OLD_VERSION" "$OLD_BUILD_PATH" "$K8S_VER")"

  log "🔧 Server: ${host_ip}"
  log "📁 Path (from Jenkins inputs): ${reset_root}"

  # Run remote steps
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@${host_ip}" bash -euo pipefail -s -- \
      "$reset_root" "$KSPRAY_DIR" "$REQ_WAIT_SECS" <<'EOSSH'
set -euo pipefail
RESET_ROOT="$1"
KSPRAY_DIR="$2"
REQ_WAIT_SECS="$3"

echo "Jenkins reset root: ${RESET_ROOT}"

if [[ ! -d "${RESET_ROOT}" ]]; then
  echo "WARN: ${RESET_ROOT} does not exist on this node. Creating directory (to proceed)..." >&2
  mkdir -p "${RESET_ROOT}"
fi

# If requirements.txt is not present, kick installer in background (existing behavior)
REQ_FILE="${RESET_ROOT}/${KSPRAY_DIR}/requirements.txt"
if [[ ! -f "${REQ_FILE}" ]]; then
  echo "⏳ ${REQ_FILE} not found → starting install_k8s.sh in background to generate it (if applicable)"
  # Run from RESET_ROOT if the script exists there; otherwise try to find it
  cd "${RESET_ROOT}" || exit 1
  if [[ -x ./install_k8s.sh ]]; then
    nohup ./install_k8s.sh > /var/log/install_k8s_bg.log 2>&1 &
    echo "[START] install_k8s.sh pid=$! (log: /var/log/install_k8s_bg.log)"
  else
    echo "WARN: install_k8s.sh not found in ${RESET_ROOT}. Background start skipped." >&2
  fi
fi

# Wait up to REQ_WAIT_SECS for requirements.txt to appear
elapsed=0
while [[ ! -f "${REQ_FILE}" && "${elapsed}" -lt "${REQ_WAIT_SECS}" ]]; do
  sleep 3
  elapsed=$((elapsed+3))
done

if [[ ! -f "${REQ_FILE}" ]]; then
  echo "❌ Timed out (${REQ_WAIT_SECS}s) waiting for ${REQ_FILE}" >&2
  # Best-effort: show any background log if present
  if [[ -f /var/log/install_k8s_bg.log ]]; then
    echo "---- /var/log/install_k8s_bg.log (tail) ----"
    tail -n 100 /var/log/install_k8s_bg.log || true
  fi
  exit 1
fi

echo "✅ Found ${REQ_FILE}"
# TODO: Keep your existing uninstall/reset steps here if they rely on RESET_ROOT/KSPRAY_DIR
# e.g., kubeadm reset, remove manifests, etc.

EOSSH
}

# ----------------
# Main entrypoint
# ----------------
log "Jenkins reset.yml: ${RESET_YML_WS}"
targets=()
while IFS= read -r ip; do
  [[ -n "$ip" ]] && targets+=("$ip")
done < <(read_targets)

if [[ ${#targets[@]} -eq 0 ]]; then
  die "No valid targets parsed from ${SERVER_FILE}"
fi

# Retry wrapper per host (preserves your RETRY_COUNT / RETRY_DELAY_SECS behavior)
for ip in "${targets[@]}"; do
  attempt=1
  while : ; do
    if reset_on_host "$ip"; then
      log "✅ Reset preparation ok on ${ip}"
      break
    fi
    if (( attempt >= RETRY_COUNT )); then
      die "Reset failed on ${ip} after ${RETRY_COUNT} attempts"
    fi
    log "WARN: Attempt ${attempt} failed on ${ip}; retrying in ${RETRY_DELAY_SECS}s..."
    sleep "${RETRY_DELAY_SECS}"
    attempt=$((attempt+1))
  done
done

log "🎉 Cluster reset stage completed for all targets (path derived from Jenkins inputs)."
