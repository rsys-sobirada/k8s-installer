#!/usr/bin/env bash
# scripts/cluster_install.sh
# Sequential install per server
# - Uses NEW_BUILD_PATH as root (normalized to /<BASE>[/<TAG>])
# - Only untars TRILLIUM_5GCN_CNF_REL_<BASE>*.tar.gz (no BINs)
# - Retries per host; waits for TRILLIUM tar if fetch runs in parallel
# - SSH key auth to root@host (and can bootstrap on Fresh_installation using password root123)
# - Success judged by kubectl health, not installer RC
# - Abort trap to clean up remote processes on abort

set -euo pipefail

# =========================== helpers ===========================
require(){ local n="$1" ex="$2"; [[ -n "${!n:-}" ]] || { echo "❌ Missing $n (e.g. $ex)"; exit 1; }; }
base_ver(){ printf '%s\n' "${1%%_*}"; }                   # 6.3.0_EA2 -> 6.3.0
ver_tag(){ [[ "$1" == *_* ]] && echo "${1##*_}" || echo ""; }  # 6.3.0_EA2 -> EA2 ; 6.3.0 -> ""

normalize_root(){  # <path> <BASE> [TAG]
  local p="${1%/}" base="$2" tag="${3-}"
  if [[ -n "$tag" && "$p" == */"$base"/"$tag" ]]; then p="${p%/$base/$tag}"
  elif [[ "$p" == */"$base" ]]; then p="${p%/$base}"
  else case "$p" in */"$base"/EA*) p="${p%/$base/*}";; esac
  fi
  echo "${p:-/}"
}

# ---------- Fresh-install SSH bootstrap (runs on Jenkins agent) ----------
: "${INSTALL_MODE:=}"               # "Fresh_installation" / "Upgrade_*"
: "${CN_ROOT_PASS:=root123}"        # hardcoded per request

ip_only_from_cidr() { printf '%s\n' "${1%%/*}"; }

ensure_local_ssh_tools() {
  if ! command -v sshpass >/dev/null 2>&1; then
    # Try apt first, then yum; ignore failures (user may preinstall)
    (command -v apt-get >/dev/null 2>&1 && apt-get update -y && apt-get install -y sshpass) \
    || (command -v yum >/dev/null 2>&1 && yum install -y epel-release sshpass) \
    || echo "[WARN] Could not auto-install sshpass; ssh-copy-id may prompt for password."
  fi
}

bootstrap_cn_ssh_if_needed() {
  local ip_only="$1"

  # If key-based SSH already works, skip
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@${ip_only}" true 2>/dev/null; then
    echo "[SSH] Key-based access already works to ${ip_only}"
    return 0
  fi

  echo "[SSH] Key-based access not working to ${ip_only} → bootstrapping using password ..."

  ensure_local_ssh_tools

  # Generate a key locally on the Jenkins agent if missing
  if [[ ! -f /root/.ssh/id_rsa ]]; then
    echo "[SSH] Generating /root/.ssh/id_rsa ..."
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    ssh-keygen -q -t rsa -N '' -f /root/.ssh/id_rsa
  fi

  # Clean known_hosts entry for the CN IP to avoid mismatches
  ssh-keygen -f "/root/.ssh/known_hosts" -R "${ip_only}" >/dev/null 2>&1 || true

  # Copy the public key to the CN using the provided password
  if command -v sshpass >/dev/null 2>&1; then
    echo "[SSH] Copying key to root@${ip_only} with sshpass ..."
    sshpass -p "${CN_ROOT_PASS}" ssh-copy-id -o StrictHostKeyChecking=no "root@${ip_only}"
  else
    echo "[SSH] sshpass not present; you may be prompted for the password (${CN_ROOT_PASS}) ..."
    ssh-copy-id -o StrictHostKeyChecking=no "root@${ip_only}"
  fi

  # (Optional) also append our pubkey to agent’s own authorized_keys (no harm)
  cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys 2>/dev/null || true
  chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true

  # Restart sshd on the CN best-effort
  ssh -o StrictHostKeyChecking=no "root@${ip_only}" 'systemctl restart sshd || systemctl restart ssh || true' || true

  # Final check
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@${ip_only}" true 2>/dev/null; then
    echo "[SSH] ✅ Passwordless SSH established to ${ip_only}"
    return 0
  else
    echo "[SSH] ❌ Still cannot SSH key-only to ${ip_only}."
    return 1
  fi
}

# =========================== inputs ===========================
require NEW_VERSION     "6.3.0_EA2"
require NEW_BUILD_PATH  "/home/labadmin"
: "${K8S_VER:=1.31.4}"
: "${SSH_KEY:=/var/lib/jenkins/.ssh/jenkins_key}"
: "${INSTALL_SERVER_FILE:=server_pci_map.txt}"   # "name:ip" or just "ip"
: "${INSTALL_IP_ADDR:=10.10.10.20/24}"           # leave empty to skip plumbing
: "${INSTALL_IP_IFACE:=}"
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
echo "Install mode:     ${INSTALL_MODE:-<unspecified>}"
echo "────────────────────────────────────────"

# =========================== abort trap ===========================
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

# =========================== remote snippets ===========================
read -r -d '' PREPARE_MNT_SNIPPET <<'RS' || true
set -euo pipefail
prep(){ local d="$1"; mkdir -p "$d"; if [ -d "$d" ]; then find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; fi; }
prep /mnt/data0; prep /mnt/data1; prep /mnt/data2
echo "[MNT] Prepared /mnt/data{0,1,2} (created if missing, contents cleared)"
RS

read -r -d '' ENSURE_IP_SNIPPET <<'RS' || true
set -euo pipefail
IP_CIDR="$1"; FORCE_IFACE="${2-}"

is_present(){ ip -4 addr show | awk '/inet /{print $2}' | grep -qx "$IP_CIDR"; }

echo "[IP] Ensuring ${IP_CIDR}"
if is_present; then
  echo "[IP] Present: ${IP_CIDR}"
  exit 0
fi

declare -a CAND=()
if [[ -n "$FORCE_IFACE" ]]; then CAND+=("$FORCE_IFACE"); fi
DEF_IF=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}' || true)
if [[ -n "${DEF_IF:-}" ]]; then CAND+=("$DEF_IF"); fi
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
    if ip -4 addr show dev "$IF" | grep -q "$IP_CIDR"; then
      echo "[IP] OK on ${IF}"
      exit 0
    fi
  fi
  echo "[IP] Failed on ${IF}: $(tr -d '\n' </tmp/ip_err_${IF}.log)" || true
done

echo "[IP] ERROR: Could not plumb ${IP_CIDR} on any iface. Candidates tried: ${CAND[*]}"
exit 2
RS

# Ensure TRILLIUM exists/extracted under <ROOT>/<BASE>/<TAG>; print extracted dir
read -r -d '' ENSURE_TRILLIUM_EXTRACTED <<'RS' || true
set -euo pipefail
ROOT="$1"; BASE="$2"; TAG="$3"; WAIT="${4:-0}"
DEST_DIR="$ROOT/$BASE/$TAG"

mkdir -p "$DEST_DIR"
shopt -s nullglob

# Already extracted?
matches=( "$DEST_DIR/TRILLIUM_5GCN_CNF_REL_${BASE}"* )
if (( ${#matches[@]} )); then
  echo "[TRIL] Found existing dir: ${matches[0]}"
  echo "${matches[0]}"
  exit 0
fi

# Candidate tars: exact + any suffix
tars=( "$DEST_DIR/TRILLIUM_5GCN_CNF_REL_${BASE}.tar.gz" "$DEST_DIR"/TRILLIUM_5GCN_CNF_REL_${BASE}*.tar.gz )

# Wait for any tar to appear
elapsed=0; interval=3; found_tar=""
while :; do
  for f in "${tars[@]}"; do
    if [[ -s "$f" ]]; then found_tar="$f"; break; fi
  done
  [[ -n "$found_tar" || $elapsed -ge $WAIT ]] && break
  echo "[TRIL] Waiting for tar in $DEST_DIR ... (${elapsed}/${WAIT}s)"
  sleep "$interval"; elapsed=$((elapsed+interval))
done

if [[ -z "$found_tar" ]]; then
  echo "[ERROR] No TRILLIUM tar found in $DEST_DIR after ${WAIT}s"; exit 2
fi

echo "[TRIL] Extracting $(basename "$found_tar") into $DEST_DIR ..."
tar -C "$DEST_DIR" -xzf "$found_tar"

# Verify again
matches=( "$DEST_DIR/TRILLIUM_5GCN_CNF_REL_${BASE}"* )
[[ ${#matches[@]} -gt 0 ]] || { echo "[ERROR] Extraction completed but directory not found under $DEST_DIR"; exit 2; }
echo "[TRIL] Extracted dir: ${matches[0]}"
echo "${matches[0]}"
RS

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

read -r -d '' RUN_INSTALL_AND_VERIFY_SNIPPET <<'RS' || true
set -euo pipefail
P="$1"; EXP_VER="${2-}"

cd "$P" || { echo "[ERROR] Path not found: $P"; exit 2; }
sed -i 's/\r$//' install_k8s.sh 2>/dev/null || true

echo "[RUN] yes yes | ./install_k8s.sh (in $P)"
set +e
yes yes | bash ./install_k8s.sh
RC=$?
set -e

# Health check: allow installer RC!=0 if cluster becomes Ready
export KUBECONFIG=/etc/kubernetes/admin.conf
READY=0
TRIES=30   # ~5 minutes @10s
for i in $(seq 1 $TRIES); do
  if kubectl get nodes >/dev/null 2>&1; then
    if kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}:{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
        | grep -q ':True$'; then
      READY=1
      break
    fi
  fi
  sleep 10
done

if [[ $READY -eq 1 ]]; then
  echo "[VERIFY] Node Ready detected."
  if [[ -n "$EXP_VER" ]]; then
    if kubectl version --short 2>/dev/null | grep -q "$EXP_VER"; then
      echo "[VERIFY] Kubernetes version matches expected: $EXP_VER"
    else
      echo "[WARN] Kubernetes version does not match expected: $EXP_VER"
    fi
  fi
  kubectl get pods -A || true
  kubectl get nodes -o wide || true
  exit 0
fi

echo "[VERIFY] Cluster not Ready after install (installer rc=$RC)."
exit 1
RS

# =========================== per-host loop ===========================
any_failed=0

# One-time prep on the *first* host we touch (we run per host for simplicity)
while IFS= read -r raw || [[ -n "${raw:-}" ]]; do
  line="$(printf '%s' "${raw:-}" | tr -d '\r')"
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

  if [[ "$line" == *:* ]]; then
    IFS=':' read -r _name ip _rest <<<"$line"
    host="$(echo -n "${ip:-}" | xargs)"
  else
    host="$(echo -n "$line" | xargs)"
  fi
  [[ -z "$host" ]] && { echo "⚠️  Skipping malformed line: $line"; continue; }

  HOSTS_TOUCHED+=("$host")

  # Prepare /mnt/data* on target
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s <<<"$PREPARE_MNT_SNIPPET"

  # Normalize ROOT from NEW_BUILD_PATH; derive TAG
  raw_base="$NEW_BUILD_PATH"
  ROOT_BASE="$(normalize_root "$raw_base" "$BASE")"

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

  echo ""
  echo "🧩 Host:  $host"
  echo "📁 Root:  $ROOT_BASE (from NEW_BUILD_PATH)"
  echo "🏷️  Tag:   $TAG"

  # Attempt loop
  attempt=1
  while (( attempt <= INSTALL_RETRY_COUNT )); do
    echo "🚀 Install attempt $attempt/$INSTALL_RETRY_COUNT on $host"

    # Ensure TRILLIUM present & extracted (wait for tar if fetch stage is parallel)
    TRIL_DIR="$(ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$ROOT_BASE" "$BASE" "$TAG" "$BUILD_WAIT_SECS" <<<"$ENSURE_TRILLIUM_EXTRACTED" | tail -n1 || true)"
    if [[ -z "$TRIL_DIR" ]]; then
      echo "⚠️  TRILLIUM not ready on $host (attempt $attempt)"
      ((attempt++))
      (( attempt <= INSTALL_RETRY_COUNT )) && { echo "⏳ Waiting ${INSTALL_RETRY_DELAY_SECS}s and retrying..."; sleep "$INSTALL_RETRY_DELAY_SECS"; }
      continue
    fi

    NEW_VER_PATH="${TRIL_DIR}/common/tools/install/k8s-v${K8S_VER}"
    echo "📁 Path:  $NEW_VER_PATH"

    # Free kube ports if needed
    ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s <<<"$FREE_PORTS_SNIPPET" || true

    # Ensure alias IP (only if configured)
    if [[ -n "${INSTALL_IP_ADDR:-}" ]]; then
      if ! ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$INSTALL_IP_ADDR" "$INSTALL_IP_IFACE" <<<"$ENSURE_IP_SNIPPET"; then
        echo "⚠️  Failed to ensure $INSTALL_IP_ADDR on $host (attempt $attempt)"
        ((attempt++))
        (( attempt <= INSTALL_RETRY_COUNT )) && { echo "⏳ Waiting ${INSTALL_RETRY_DELAY_SECS}s and retrying..."; sleep "$INSTALL_RETRY_DELAY_SECS"; }
        continue
      fi
    else
      echo "[IP] Skipping ensure; INSTALL_IP_ADDR is empty"
    fi

    # On Fresh_installation: bootstrap passwordless SSH using INSTALL_IP_ADDR (IP-only)
    if [[ "${INSTALL_MODE:-}" == "Fresh_installation" ]]; then
      ip_only="$(ip_only_from_cidr "${INSTALL_IP_ADDR:-}")"
      if [[ -n "$ip_only" ]]; then
        bootstrap_cn_ssh_if_needed "$ip_only" || true
      fi
    fi

    # Run installer and verify health
    if ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$NEW_VER_PATH" "$K8S_VER" <<<"$RUN_INSTALL_AND_VERIFY_SNIPPET"; then
      echo "✅ Install verified healthy on $host"
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
