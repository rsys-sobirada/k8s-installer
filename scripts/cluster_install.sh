#!/usr/bin/env bash
# scripts/cluster_install.sh
# Sequential install per server
# - Uses NEW_BUILD_PATH as root (normalized to /<BASE>[/<TAG>])
# - Pre-check: create /mnt/data{0,1,2} and clear contents
# - Only untars TRILLIUM_5GCN_CNF_REL_<BASE>*.tar.gz (no BINs)
# - Preflight: ensure kube ports 6443/10257 are free
# - Streams install_k8s.sh output live to Jenkins
# - SSH key auth to root@host
# - If Ansible shows "Permission denied (publickey,password)" → print ANSIBLE_SSH_DENIED (bootstrap handled externally)
# - On DEPLOYMENT_TYPE=LOW, comment kubelet tuning in k8s-cluster.yml right before install

# ---- helpers ----
require(){ local n="$1" ex="$2"; [[ -n "${!n:-}" ]] || { echo "❌ Missing $n (e.g. $ex)"; exit 1; }; }
base_ver(){ echo "${1%%_*}"; }                                   # 6.3.0_EA2 -> 6.3.0
ver_tag(){ [[ "$1" == *_* ]] && echo "${1##*_}" || echo ""; }    # 6.3.0_EA2 -> EA2 ; 6.3.0 -> ""

ip_only_from_cidr(){ local s="${1:-}"; s="${s%%/*}"; echo -n "$s"; }

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
: "${SSH_KEY:=/var/lib/jenkins/.ssh/jenkins_key}"
: "${INSTALL_SERVER_FILE:=server_pci_map.txt}"   # "name:ip" or just "ip"
: "${INSTALL_IP_ADDR:=10.10.10.20/24}"           # optional; skip if empty
: "${INSTALL_IP_IFACE:=}"
: "${INSTALL_MODE:=}"                             # Fresh_installation / Upgrade_*
: "${DEPLOYMENT_TYPE:=}"                          # Low / Medium / High (case-insensitive)

# Retries / waits
: "${INSTALL_RETRY_COUNT:=3}"
: "${INSTALL_RETRY_DELAY_SECS:=20}"
: "${BUILD_WAIT_SECS:=300}"

[[ -f "$SSH_KEY" ]] || { echo "❌ SSH key not found: $SSH_KEY"; exit 1; }
chmod 600 "$SSH_KEY" || true
[[ -f "$INSTALL_SERVER_FILE" ]] || { echo "❌ Missing $INSTALL_SERVER_FILE"; exit 1; }

SSH_OPTS='-o BatchMode=yes -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=5m -o ControlPath=/tmp/ssh_mux_%h_%p_%r'

BASE="$(base_ver "$NEW_VERSION")"
TAG_IN="$(ver_tag "$NEW_VERSION")"

echo "NEW_VERSION:      $NEW_VERSION"
echo "NEW_BUILD_PATH:   $NEW_BUILD_PATH"
echo "BASE version:     $BASE"
[[ -n "$TAG_IN" ]] && echo "Provided TAG:   $TAG_IN" || echo "Provided TAG:   (none; will detect per host)"
echo "INSTALL_LIST:     $INSTALL_SERVER_FILE"
echo "IP to ensure:     ${INSTALL_IP_ADDR:-<skipped>}"
echo "Install mode:     ${INSTALL_MODE:-<unknown>}"
echo "────────────────────────────────────────"

# ---- remote snippets ----

# 0) Prepare /mnt/data{0,1,2}
read -r -d '' PREPARE_MNT_SNIPPET <<'RS' || true
set -euo pipefail
prep(){ local d="$1"; mkdir -p "$d"; if [ -d "$d" ]; then find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; fi; }
prep /mnt/data0; prep /mnt/data1; prep /mnt/data2
echo "[MNT] Prepared /mnt/data{0,1,2} (created if missing, contents cleared)"
RS

# 1) Ensure alias IP exists (robust)
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
echo "[IP] ERROR: Could not plumb ${IP_CIDR} on any iface. Candidates tried: ${CAND[*]}"; exit 2
RS

# 2) Ensure ONLY TRILLIUM is extracted under <ROOT>/<BASE>/<TAG>; returns DIR path
read -r -d '' ENSURE_TRILLIUM_EXTRACTED <<'RS' || true
set -euo pipefail
ROOT="$1"; BASE="$2"; TAG="$3"; WAIT="${4:-0}"
DEST_DIR="$ROOT/$BASE/$TAG"
mkdir -p "$DEST_DIR"
shopt -s nullglob
# already extracted? directory with prefix
dir_candidates=( "$DEST_DIR"/TRILLIUM_5GCN_CNF_REL_${BASE}*/ )
if (( ${#dir_candidates[@]} )); then
  echo "${dir_candidates[0]%/}"; exit 0
fi
# wait for tar
exact="$DEST_DIR/TRILLIUM_5GCN_CNF_REL_${BASE}.tar.gz"
wild=( "$DEST_DIR"/TRILLIUM_5GCN_CNF_REL_${BASE}*.tar.gz )
elapsed=0; interval=3; tarfile=""
while :; do
  [[ -s "$exact" ]] && { tarfile="$exact"; break; }
  for f in "${wild[@]}"; do [[ -s "$f" ]] && { tarfile="$f"; break; }; done
  [[ -n "$tarfile" || $elapsed -ge $WAIT ]] && break
  echo "[TRIL] Waiting for tar in $DEST_DIR ... (${elapsed}/${WAIT}s)"; sleep "$interval"; elapsed=$((elapsed+interval))
done
[[ -n "$tarfile" ]] || { echo "[ERROR] No TRILLIUM tar found in $DEST_DIR after ${WAIT}s"; exit 2; }
echo "[TRIL] Extracting $(basename "$tarfile") into $DEST_DIR ..."
tar -C "$DEST_DIR" -xzf "$tarfile"
dir_candidates=( "$DEST_DIR"/TRILLIUM_5GCN_CNF_REL_${BASE}*/ )
[[ ${#dir_candidates[@]} -gt 0 ]] || { echo "[ERROR] Extraction completed but directory not found under $DEST_DIR"; exit 2; }
echo "${dir_candidates[0]%/}"
RS

# 3) Preflight: ensure kube ports are free
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

# 4) Comment kubelet tuning for DEPLOYMENT_TYPE=LOW (before install)
read -r -d '' LOW_CAPACITY_TWEAK <<'RS' || true
set -euo pipefail
K8S_YAML="$1"
if [[ -f "$K8S_YAML" ]]; then
  echo "[LOW] Commenting kubelet CPU/NUMA settings in: $K8S_YAML"
  sed -i \
    -e 's/^\(\s*kubelet_cpu_manager_policy:.*\)$/# \1/' \
    -e 's/^\(\s*kubelet_topology_manager_policy:.*\)$/# \1/' \
    -e 's/^\(\s*kubelet_topology_manager_scope:.*\)$/# \1/' \
    -e 's/^\(\s*reserved_system_cpus:.*\)$/# \1/' \
    "$K8S_YAML"
else
  echo "[LOW] WARNING: k8s-cluster.yml not found at $K8S_YAML"
fi
RS

# 5) Run installer (stream logs). We stream on the agent by stdbuf on the remote.
read -r -d '' RUN_INSTALL_STREAMING <<'RS' || true
set -euo pipefail
P="$1"
cd "$P" || { echo "[ERROR] Path not found: $P"; exit 2; }
sed -i 's/\r$//' install_k8s.sh 2>/dev/null || true
echo "[RUN] yes yes | ./install_k8s.sh (in $P)"
set +e
stdbuf -oL -eL yes yes | bash ./install_k8s.sh
RC=$?
set -e
exit $RC
RS

any_failed=0

# ---- per-host loop ----
while IFS= read -r raw || [[ -n "${raw:-}" ]]; do
  line="$(echo -n "${raw:-}" | tr -d '\r')"
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

  if [[ "$line" == *:* ]]; then
    IFS=':' read -r _name ip _rest <<<"$line"; host="$(echo -n "${ip:-}" | xargs)"
  else
    host="$(echo -n "$line" | xargs)"
  fi
  [[ -z "$host" ]] && { echo "⚠️  Skipping malformed line: $line"; continue; }

  # 0) Prepare /mnt on every host
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s <<<"$PREPARE_MNT_SNIPPET"

  # Normalize ROOT from NEW_BUILD_PATH
  raw_base="$NEW_BUILD_PATH"
  ROOT_BASE="$(normalize_root "$raw_base" "$BASE")"

  # Determine TAG (if not provided)
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
  echo ""; echo "🧩 Host:  $host"; echo "📁 Root:  $ROOT_BASE (from NEW_BUILD_PATH)"; echo "🏷️  Tag:   $TAG"

  # Ensure TRILLIUM present & extracted (returns directory)
  TRIL_DIR="$(ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$ROOT_BASE" "$BASE" "$TAG" "$BUILD_WAIT_SECS" <<<"$ENSURE_TRILLIUM_EXTRACTED" | tail -n1 || true)"
  if [[ -z "$TRIL_DIR" ]]; then
    echo "⚠️  TRILLIUM not ready on $host"; any_failed=1; continue
  fi

  NEW_VER_PATH="${TRIL_DIR}/common/tools/install/k8s-v${K8S_VER}"
  K8S_YAML="${NEW_VER_PATH}/k8s-yamls/k8s-cluster.yml"
  echo "📁 Path:  $NEW_VER_PATH"
  if [[ -z "$NEW_VER_PATH" ]]; then echo "[ERROR] NEW_VER_PATH empty"; any_failed=1; continue; fi

  # Free kube ports if needed
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s <<<"$FREE_PORTS_SNIPPET" || true

  # Ensure alias IP (only if configured)
  if [[ -n "${INSTALL_IP_ADDR:-}" ]]; then
    ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$INSTALL_IP_ADDR" "$INSTALL_IP_IFACE" <<<"$ENSURE_IP_SNIPPET" || true
  else
    echo "[IP] Skipping ensure; INSTALL_IP_ADDR is empty"
  fi

  # LOW footprint tweak BEFORE install
  if [[ "${DEPLOYMENT_TYPE,,}" == "low" ]]; then
    ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$K8S_YAML" <<<"$LOW_CAPACITY_TWEAK"
  fi

  # Run installer (live stream) and mirror to temp log to detect SSH denied
  echo "[RUN] Starting installer on $host ..."
  tmp_log="/tmp/install_k8s_${host}_$$.log"
  set +e
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$NEW_VER_PATH" <<<"$RUN_INSTALL_STREAMING" \
    | tee "$tmp_log"
  RUN_RC=${PIPESTATUS[0]}
  set -e

  if grep -q 'Permission denied (publickey,password)' "$tmp_log"; then
    echo "ANSIBLE_SSH_DENIED"
    rm -f "$tmp_log" || true
    any_failed=1
    continue
  fi
  rm -f "$tmp_log" || true

  if [[ $RUN_RC -eq 0 ]]; then
    echo "✅ Install verified healthy on $host"
  else
    echo "❌ Install failed on $host (rc=$RUN_RC)"
    # Optional deep cleanup between attempts (kept from your original)
    ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s <<<"$RESET_KUBE_SNIPPET" || true
    any_failed=1
  fi

done < "$INSTALL_SERVER_FILE"

echo ""
if [[ $any_failed -ne 0 ]]; then
  echo "❌ One or more installs failed."
  exit 1
fi
echo "🎉 Install step completed (installer invoked on all hosts)."
