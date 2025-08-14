#!/bin/bash
# scripts/cluster_install.sh
# Sequential install per server
# - Always uses NEW_BUILD_PATH as root (normalized to /<BASE>[/<TAG>])
# - Pre-check: create /mnt/data{0,1,2} and clear contents
# - Only untars TRILLIUM_5GCN_CNF_REL_<BASE>.tar.gz (no BINs)
# - Preflight: ensure kube ports 6443/10257 are free
# - Retries end-to-end per host (waits for TRILLIUM tar if fetch runs in parallel)
# - SSH key auth to root@host
# - Abort trap: kills remote activity and frees kube ports on pipeline abort

set -euo pipefail

# ---- helpers ----
require(){ local n="$1" ex="$2"; [[ -n "${!n:-}" ]] || { echo "❌ Missing $n (e.g. $ex)"; exit 1; }; }
base_ver(){ echo "${1%%_*}"; }                                   # 6.3.0_EA2 -> 6.3.0
ver_tag(){ [[ "$1" == *_* ]] && echo "${1##*_}" || echo ""; }    # 6.3.0_EA2 -> EA2 ; 6.3.0 -> ""

make_k8s_path(){  # <root> <BASE> <TAG> <K8S_VER> [REL_SUFFIX]
  local root="${1%/}" base="$2" tag="$3" kver="$4" rel="${5-}"
  echo "$root/${base}/${tag}/TRILLIUM_5GCN_CNF_REL_${base}${rel}/common/tools/install/k8s-v${kver}"
}

normalize_root(){  # <path> <BASE> [TAG]
  local p="${1%/}" base="$2" tag="${3-}"
  if [[ -n "$tag" && "$p" == */"$base"/"$tag" ]]; then p="${p%/$base/$tag}"
  elif [[ "$p" == */"$base" ]]; then p="${p%/$base}"
  else case "$p" in */"$base"/EA*) p="${p%/$base/*}";; esac
  fi
  echo "${p:-/}"
}

# ---- inputs ----
require NEW_VERSION     "6.3.0_EA2"
require NEW_BUILD_PATH  "/home/labadmin"
: "${K8S_VER:=1.31.4}"
: "${REL_SUFFIX:=}"
: "${SSH_KEY:=/var/lib/jenkins/.ssh/jenkins_key}"
: "${INSTALL_SERVER_FILE:=server_pci_map.txt}"   # "name:ip" or just "ip"
: "${INSTALL_IP_ADDR:=10.10.10.20/24}"
: "${INSTALL_IP_IFACE:=}"

# Retries / waits
: "${INSTALL_RETRY_COUNT:=3}"           # attempts per host
: "${INSTALL_RETRY_DELAY_SECS:=20}"     # delay between attempts
: "${BUILD_WAIT_SECS:=300}"             # wait for TRILLIUM tar (fetch may be parallel)

[[ -f "$SSH_KEY" ]] || { echo "❌ SSH key not found: $SSH_KEY"; exit 1; }
chmod 600 "$SSH_KEY" || true
[[ -f "$INSTALL_SERVER_FILE" ]] || { echo "❌ Missing $INSTALL_SERVER_FILE"; exit 1; }

SSH_OPTS='-o BatchMode=yes -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=5m -o ControlPath=/tmp/ssh_mux_%h_%p_%r'

BASE="$(base_ver "$NEW_VERSION")"
TAG_IN="$(ver_tag "$NEW_VERSION")"

# ---- Abort trap ----
declare -a HOSTS_TOUCHED=()
ABORTING=0
on_abort() {
  [[ $ABORTING -eq 1 ]] && return
  ABORTING=1
  echo ""
  echo "⚠️  Abort received — stopping remote actions on touched hosts..."
  for host in "${HOSTS_TOUCHED[@]}"; do
    ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s <<'RS'
set -euo pipefail
pkill -f 'install_k8s\.sh|ansible-playbook|kubeadm|kubespray' 2>/dev/null || true
systemctl stop kubelet || true
rm -f /etc/kubernetes/manifests/*.yaml || true
if command -v crictl >/dev/null 2>&1; then
  crictl ps -a | awk '{print $1}' | xargs -r crictl rm -f
fi
RS
  done
  echo "🔚 Exiting due to abort."
  exit 130
}
trap on_abort INT TERM HUP QUIT

echo "NEW_VERSION:      $NEW_VERSION"
echo "NEW_BUILD_PATH:   $NEW_BUILD_PATH"
echo "BASE version:     $BASE"
[[ -n "$TAG_IN" ]] && echo "Provided TAG:   $TAG_IN" || echo "Provided TAG:   (none; will detect per host)"
echo "INSTALL_LIST:     $INSTALL_SERVER_FILE"
echo "IP to ensure:     $INSTALL_IP_ADDR"
[[ -n "$INSTALL_IP_IFACE" ]] && echo "Forced iface:    $INSTALL_IP_IFACE"
echo "────────────────────────────────────────"

# ---- remote snippets ----

# 0) Prepare /mnt/data{0,1,2}
read -r -d '' PREPARE_MNT_SNIPPET <<'RS' || true
set -euo pipefail
prep(){ local d="$1"; mkdir -p "$d"; if [ -d "$d" ]; then find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; fi; }
prep /mnt/data0; prep /mnt/data1; prep /mnt/data2
echo "[MNT] Prepared /mnt/data{0,1,2} (created if missing, contents cleared)"
RS

# 1) Ensure alias IP exists
read -r -d '' ENSURE_IP_SNIPPET <<'RS' || true
set -euo pipefail
IP_CIDR="$1"; FORCE_IFACE="${2-}"
present(){ ip -4 addr show | grep -q -E "[[:space:]]${IP_CIDR%/*}(/|[[:space:]])"; }
if present; then echo "[IP] Present: ${IP_CIDR}"; exit 0; fi
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
RS

# 2) Ensure ONLY TRILLIUM is extracted under <ROOT>/<BASE>/<TAG>, waiting for tar if needed
# $1=root_base_dir (normalized), $2=BASE, $3=TAG, $4=REL_SUFFIX, $5=WAIT_SECS
read -r -d '' ENSURE_TRILLIUM_EXTRACTED <<'RS' || true
set -euo pipefail
ROOT="$1"; BASE="$2"; TAG="$3"; REL="${4-}"; WAIT="${5:-0}"
DEST_DIR="$ROOT/$BASE/$TAG"
TRIL_DIR="$DEST_DIR/TRILLIUM_5GCN_CNF_REL_${BASE}${REL}"
TRIL_TAR="$DEST_DIR/TRILLIUM_5GCN_CNF_REL_${BASE}.tar.gz"

mkdir -p "$DEST_DIR"

if [[ -d "$TRIL_DIR" ]]; then
  echo "[TRIL] Already extracted at $TRIL_DIR"; exit 0
fi

elapsed=0
interval=3
while [[ ! -s "$TRIL_TAR" && "$elapsed" -lt "$WAIT" ]]; do
  echo "[TRIL] Waiting for $TRIL_TAR to appear ... (${elapsed}/${WAIT}s)"
  sleep "$interval"; elapsed=$((elapsed+interval))
done

if [[ ! -s "$TRIL_TAR" ]]; then
  echo "[ERROR] TRILLIUM tar not found at $TRIL_TAR after ${WAIT}s"; exit 2
fi

echo "[TRIL] Extracting $TRIL_TAR into $DEST_DIR ..."
tar -C "$DEST_DIR" -xzf "$TRIL_TAR"
[[ -d "$TRIL_DIR" ]] || { echo "[ERROR] Extraction completed but $TRIL_DIR not found"; exit 2; }
RS

# 3) Preflight: ensure kube ports are free (6443/10257)
read -r -d '' FREE_PORTS_SNIPPET <<'RS' || true
set -euo pipefail
needs_free(){ ss -ltn | egrep -q ":(6443|10257)\s"; }
if needs_free; then
  echo "[PRE] Ports 6443/10257 busy → stopping kubelet & removing static pods"
  systemctl stop kubelet || true
  rm -f /etc/kubernetes/manifests/*.yaml || true
  pkill -f 'kube-apiserver|kube-controller-manager|kube-scheduler' 2>/dev/null || true
  if command -v crictl >/dev/null 2>&1; then
    crictl ps -a | awk '/kube-apiserver|kube-controller-manager|kube-scheduler/{print $1}' | xargs -r crictl rm -f
  fi
fi
RS

# 3b) Stronger cleanup between retries (includes kubeadm reset)
read -r -d '' RESET_KUBE_SNIPPET <<'RS' || true
set -euo pipefail
systemctl stop kubelet || true
rm -f /etc/kubernetes/manifests/*.yaml || true
kubeadm reset -f || true
rm -rf /var/lib/etcd /etc/kubernetes/* /var/lib/kubelet/* 2>/dev/null || true
if command -v crictl >/dev/null 2>&1; then
  crictl ps -a | awk '{print $1}' | xargs -r crictl rm -f
fi
RS

# 4) Run installer
# $1=install_path
read -r -d '' RUN_INSTALL_SNIPPET <<'RS' || true
set -euo pipefail
P="$1"
cd "$P" || { echo "[ERROR] Path not found: $P"; exit 2; }
sed -i 's/\r$//' install_k8s.sh 2>/dev/null || true
echo "[RUN] yes yes | ./install_k8s.sh (in $P)"
yes yes | bash ./install_k8s.sh
RS

any_failed=0

# ---- per-host loop ----
while IFS= read -r raw || [[ -n "${raw:-}" ]]; do
  line="$(echo -n "${raw:-}" | tr -d '\r')"
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

  if [[ "$line" == *:* ]]; then
    IFS=':' read -r _name ip _rest <<<"$line"
    host="$(echo -n "${ip:-}" | xargs)"
  else
    host="$(echo -n "$line" | xargs)"
  fi
  [[ -z "$host" ]] && { echo "⚠️  Skipping malformed line: $line"; continue; }

  HOSTS_TOUCHED+=("$host")

  # Prep /mnt on every host (once before attempts)
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s <<<"$PREPARE_MNT_SNIPPET"

  # Normalize ROOT from NEW_BUILD_PATH
  raw_base="$NEW_BUILD_PATH"
  ROOT_BASE="$(normalize_root "$raw_base" "$BASE")"

  # Determine TAG (once; then reuse across attempts)
  TAG="$TAG_IN"
  if [[ -z "$TAG" ]]; then
    TAG="$(ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$ROOT_BASE" "$BASE" <<'RS'
set -euo pipefail
BDIR="$1"; BASE="$2"
shopt -s nullglob
cands=( "$BDIR/$BASE"/EA* )
if (( ${#cands[@]} > 0 )); then
  for i in "${!cands[@]}"; do cands[$i]="$(basename "${cands[$i]}")"; done
  printf '%s\n' "${cands[@]}" | sort -V | tail -n1
else
  echo "EA1"
fi
RS
    )" || TAG="EA1"
  fi

  ROOT_BASE="$(normalize_root "$raw_base" "$BASE" "$TAG")"
  NEW_VER_PATH="$(make_k8s_path "$ROOT_BASE" "$BASE" "$TAG" "$K8S_VER" "$REL_SUFFIX")"

  echo ""
  echo "🧩 Host:  $host"
  echo "📁 Root:  $ROOT_BASE (from NEW_BUILD_PATH)"
  echo "🏷️  Tag:   $TAG"
  echo "📁 Path:  $NEW_VER_PATH"

  # Attempt loop
  attempt=1
  while (( attempt <= INSTALL_RETRY_COUNT )); do
    echo "🚀 Install attempt $attempt/$INSTALL_RETRY_COUNT on $host"

    # Ensure TRILLIUM present & extracted (waits for tar if fetch is still running)
    if ! ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$ROOT_BASE" "$BASE" "$TAG" "$REL_SUFFIX" "$BUILD_WAIT_SECS" <<<"$ENSURE_TRILLIUM_EXTRACTED"; then
      echo "⚠️  TRILLIUM not ready on $host (attempt $attempt)"
      ((attempt++))
      (( attempt <= INSTALL_RETRY_COUNT )) && { echo "⏳ Waiting ${INSTALL_RETRY_DELAY_SECS}s and retrying..."; sleep "$INSTALL_RETRY_DELAY_SECS"; }
      continue
    fi

    # Free ports if needed
    ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s <<<"$FREE_PORTS_SNIPPET" || true

    # Ensure alias IP
    if ! ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$INSTALL_IP_ADDR" "$INSTALL_IP_IFACE" <<<"$ENSURE_IP_SNIPPET"; then
      echo "⚠️  Failed to ensure $INSTALL_IP_ADDR on $host (attempt $attempt)"
      ((attempt++))
      (( attempt <= INSTALL_RETRY_COUNT )) && { echo "⏳ Waiting ${INSTALL_RETRY_DELAY_SECS}s and retrying..."; sleep "$INSTALL_RETRY_DELAY_SECS"; }
      continue
    fi

    # Run installer
    if ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$NEW_VER_PATH" <<<"$RUN_INSTALL_SNIPPET"; then
      echo "✅ Install triggered on $host"
      break
    fi

    echo "⚠️  Install attempt $attempt failed on $host"
    ((attempt++))
    if (( attempt <= INSTALL_RETRY_COUNT )); then
      echo "🧹 Performing stronger cleanup (kubeadm reset) before retry..."
      ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s <<<"$RESET_KUBE_SNIPPET" || true
      echo "⏳ Waiting ${INSTALL_RETRY_DELAY_SECS}s and retrying..."
      sleep "$INSTALL_RETRY_DELAY_SECS"
    fi
  done

  if (( attempt > INSTALL_RETRY_COUNT )); then
    echo "❌ Install failed after $INSTALL_RETRY_COUNT attempts on $host"
    any_failed=1
  fi
done < "$INSTALL_SERVER_FILE"

echo ""
if [[ $any_failed -ne 0 ]]; then
  echo "❌ One or more installs failed."
  exit 1
fi
echo "🎉 Install step completed (installer invoked on all hosts)."
