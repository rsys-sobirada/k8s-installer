#!/usr/bin/env bash
# scripts/cluster_install.sh
# Sequential install per server
# - Uses NEW_BUILD_PATH as root (normalized to /<BASE>[/<TAG>])
# - Pre-check: create /mnt/data{0,1,2} and clear contents
# - Only untars TRILLIUM_5GCN_CNF_REL_<BASE>.tar.gz (no BINs)
# - Preflight: ensure kube ports 6443/10257 are free
# - Retries end-to-end per host (waits for TRILLIUM tar if fetch runs in parallel)
# - SSH key auth to root@host
# - If SSH fails on Fresh_installation and CN_ROOT_PASS provided, auto-bootstrap ssh keys (sshpass + ssh-copy-id)
# - Success judged by kubectl health, not installer RC
# - Abort trap: kills remote activity on pipeline abort

set -euo pipefail

# ---- helpers ----
require(){ local n="$1" ex="$2"; [[ -n "${!n:-}" ]] || { echo "❌ Missing $n (e.g. $ex)"; exit 1; }; }
base_ver(){ echo "${1%%_*}"; }                                   # 6.3.0_EA2 -> 6.3.0
ver_tag(){ [[ "$1" == *_* ]] && echo "${1##*_}" || echo ""; }    # 6.3.0_EA2 -> EA2 ; 6.3.0 -> ""

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
: "${INSTALL_IP_ADDR:=10.10.10.20/24}"           # leave empty to skip plumbing
: "${INSTALL_IP_IFACE:=}"
: "${INSTALL_MODE:=}"                             # Fresh_installation / Upgrade_*
: "${CN_ROOT_USER:=root}"
: "${CN_ROOT_PASS:=}"                             # if provided + Fresh_installation, we can auto-bootstrap ssh keys

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

# ---- ssh bootstrap (for Fresh_installation when password is provided) ----
bootstrap_ssh_if_needed() {
  local host="$1"

  # Only on Fresh installation and only if we have a password to use
  [[ "${INSTALL_MODE}" == "Fresh_installation" ]] || return 0
  [[ -n "${CN_ROOT_PASS}" ]] || return 0

  # Prefer IP from INSTALL_IP_ADDR (strip CIDR), else fall back to "host"
  local alias_ip=""
  if [[ -n "${INSTALL_IP_ADDR:-}" ]]; then
    alias_ip="${INSTALL_IP_ADDR%%/*}"   # e.g., 10.10.10.20 from 10.10.10.20/24
  fi
  local target_ip="${alias_ip:-$host}"

  # If we can already SSH with key to the target IP, nothing to do
  if ssh $SSH_OPTS -i "$SSH_KEY" -o ConnectTimeout=5 "${CN_ROOT_USER}@${target_ip}" "echo ok" >/dev/null 2>&1; then
    return 0
  fi

  echo "[SSH-BOOTSTRAP] Setting up key-based access on ${target_ip} for ${CN_ROOT_USER} (Fresh_installation)"

  # Need sshpass + ssh-copy-id on Jenkins agent
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "❌ sshpass not found on Jenkins agent; cannot bootstrap SSH keys." >&2
    return 1
  fi
  if ! command -v ssh-copy-id >/dev/null 2>&1; then
    echo "❌ ssh-copy-id not found on Jenkins agent; cannot bootstrap SSH keys." >&2
    return 1
  fi

  # Ensure local keypair exists
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh || true
  if [[ ! -s ~/.ssh/id_rsa ]]; then
    ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa
  fi

  # We’ll try to install both ~/.ssh/id_rsa.pub and ${SSH_KEY}.pub if present
  local publist=()
  [[ -s ~/.ssh/id_rsa.pub ]] && publist+=("~/.ssh/id_rsa.pub")
  [[ -s "${SSH_KEY}.pub"    ]] && publist+=("${SSH_KEY}.pub")

  # Remove old known_hosts entry for the target IP
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "${target_ip}" >/dev/null 2>&1 || true

  # Copy keys using password
  for pub in "${publist[@]}"; do
    echo "[SSH-BOOTSTRAP] Installing public key $(basename "$pub") on ${target_ip}"
    if ! SSH_ASKPASS=/bin/false sshpass -p "${CN_ROOT_PASS}" \
        ssh-copy-id -i "${pub/#\~/$HOME}" \
        -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
        "${CN_ROOT_USER}@${target_ip}" >/dev/null 2>&1; then
      echo "⚠️  ssh-copy-id failed for key $(basename "$pub") on ${target_ip} (continuing)"
    fi
  done

  # Fallback: append id_rsa.pub directly
  if ! ssh $SSH_OPTS -i "$SSH_KEY" -o ConnectTimeout=5 "${CN_ROOT_USER}@${target_ip}" "echo ok" >/dev/null 2>&1; then
    echo "[SSH-BOOTSTRAP] Fallback: append local id_rsa.pub via sshpass"
    sshpass -p "${CN_ROOT_PASS}" ssh -o StrictHostKeyChecking=no "${CN_ROOT_USER}@${target_ip}" \
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
      < ~/.ssh/id_rsa.pub || true
  fi

  # Restart sshd on the target (as per your steps)
  sshpass -p "${CN_ROOT_PASS}" ssh -o StrictHostKeyChecking=no "${CN_ROOT_USER}@${target_ip}" "systemctl restart sshd" >/dev/null 2>&1 || true

  # Final test using the pipeline SSH key
  if ssh $SSH_OPTS -i "$SSH_KEY" -o ConnectTimeout=5 "${CN_ROOT_USER}@${target_ip}" "echo ok" >/dev/null 2>&1; then
    echo "[SSH-BOOTSTRAP] ✅ Key-based access confirmed on ${target_ip}"
    return 0
  else
    echo "[SSH-BOOTSTRAP] ❌ Still cannot SSH to ${target_ip} with key after bootstrap."
    return 1
  fi
}


# ---- Abort trap ----
declare -a HOSTS_TOUCHED=()
ABORTING=0
on_abort() {
  [[ $ABORTING -eq 1 ]] && return
  ABORTING=1
  echo ""
  echo "⚠️  Abort received — stopping remote actions on touched hosts..."
  for host in "${HOSTS_TOUCHED[@]}"; do
    ssh $SSH_OPTS -i "$SSH_KEY" "${CN_ROOT_USER}@${host}" bash -s <<'RS'
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
echo "IP to ensure:     ${INSTALL_IP_ADDR:-<skipped>}"
[[ -n "${INSTALL_MODE:-}" ]] && echo "Install mode:     ${INSTALL_MODE}"
[[ -n "$INSTALL_IP_IFACE" ]] && echo "Forced iface:    $INSTALL_IP_IFACE"
echo "────────────────────────────────────────"

# ---- remote snippets (unchanged core) ----
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
if is_present; then echo "[IP] Present: ${IP_CIDR}"; exit 0; fi
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

read -r -d '' ENSURE_TRILLIUM_EXTRACTED <<'RS' || true
set -euo pipefail
ROOT="$1"; BASE="$2"; TAG="${3:-}"; WAIT="${4:-0}"
if [[ -n "$TAG" ]]; then
  DEST_DIR="$ROOT/$BASE/$TAG"
else
  DEST_DIR="$ROOT/$BASE"
fi
mkdir -p "$DEST_DIR"
shopt -s nullglob
dir_matches=()
for f in "$DEST_DIR"/TRILLIUM_5GCN_CNF_REL_${BASE}*; do
  [[ -d "$f" ]] && dir_matches+=("$f")
done
if (( ${#dir_matches[@]} )); then
  echo "[TRIL] Found existing dir: ${dir_matches[0]}"; echo "${dir_matches[0]}"; exit 0
fi
tarball="$DEST_DIR/TRILLIUM_5GCN_CNF_REL_${BASE}.tar.gz"
elapsed=0; interval=3
while [[ ! -s "$tarball" && $elapsed -lt $WAIT ]]; do
  echo "[TRIL] Waiting for $tarball ... (${elapsed}/${WAIT}s)"
  sleep "$interval"; elapsed=$((elapsed+interval))
end
if [[ ! -s "$tarball" ]]; then
  echo "[ERROR] Required tarball not found: $tarball (waited ${WAIT}s)"; exit 2
fi
command -v tar >/dev/null 2>&1 || { echo "[ERROR] tar not found on host"; exit 2; }
echo "[TRIL] Extracting $(basename "$tarball") into $DEST_DIR ..."
tar -C "$DEST_DIR" -xzf "$tarball"
dir_matches=()
for f in "$DEST_DIR"/TRILLIUM_5GCN_CNF_REL_${BASE}*; do
  [[ -d "$f" ]] && dir_matches+=("$f")
done
[[ ${#dir_matches[@]} -gt 0 ]] || { echo "[ERROR] Extraction completed but directory not found under $DEST_DIR"; exit 2; }
echo "[TRIL] Extracted dir: ${dir_matches[0]}"
echo "${dir_matches[0]}"
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
export KUBECONFIG=/etc/kubernetes/admin.conf
READY=0; TRIES=30
for i in $(seq 1 $TRIES); do
  if kubectl get nodes >/dev/null 2>&1; then
    if kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}:{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' | grep -q ':True$'; then
      READY=1; break
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

  # Try a quick SSH to see if key-based auth already works; if not, bootstrap when allowed
  if ! ssh $SSH_OPTS -i "$SSH_KEY" -o ConnectTimeout=5 "${CN_ROOT_USER}@${host}" "echo ok" >/dev/null 2>&1; then
    if ! bootstrap_ssh_if_needed "$host"; then
      echo "❌ Cannot establish SSH key auth to ${host}; skipping host."
      any_failed=1
      continue
    fi
  fi

  # Prep /mnt on every host
  ssh $SSH_OPTS -i "$SSH_KEY" "${CN_ROOT_USER}@${host}" bash -s <<<"$PREPARE_MNT_SNIPPET"

  # Normalize ROOT from NEW_BUILD_PATH
  raw_base="$NEW_BUILD_PATH"
  ROOT_BASE="$(normalize_root "$raw_base" "$BASE")"

  # Determine TAG (once; then reuse across attempts)
  TAG="$TAG_IN"
  if [[ -z "$TAG" ]]; then
    TAG="$(ssh $SSH_OPTS -i "$SSH_KEY" "${CN_ROOT_USER}@${host}" bash -s -- "$ROOT_BASE" "$BASE" <<'RS'
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

  if [[ -n "$TAG" ]]; then
    ROOT_BASE="$(normalize_root "$raw_base" "$BASE" "$TAG")"
  else
    ROOT_BASE="$(normalize_root "$raw_base" "$BASE")"
  fi

  echo ""
  echo "🧩 Host:  $host"
  echo "📁 Root:  $ROOT_BASE (from NEW_BUILD_PATH)"
  echo "🏷️  Tag:   ${TAG:-<none>}"

  # Attempt loop
  attempt=1
  while (( attempt <= INSTALL_RETRY_COUNT )); do
    echo "🚀 Install attempt $attempt/$INSTALL_RETRY_COUNT on $host"

    # Ensure TRILLIUM present & extracted (waits for tar if fetch is still running)
    TRIL_DIR="$(ssh $SSH_OPTS -i "$SSH_KEY" "${CN_ROOT_USER}@${host}" bash -s -- "$ROOT_BASE" "$BASE" "$TAG" "$BUILD_WAIT_SECS" <<<"$ENSURE_TRILLIUM_EXTRACTED" | tail -n1 || true)"
    if [[ -z "$TRIL_DIR" ]]; then
      echo "⚠️  TRILLIUM not ready on $host (attempt $attempt)"
      ((attempt++))
      (( attempt <= INSTALL_RETRY_COUNT )) && { echo "⏳ Waiting ${INSTALL_RETRY_DELAY_SECS}s and retrying..."; sleep "$INSTALL_RETRY_DELAY_SECS"; }
      continue
    fi

    NEW_VER_PATH="${TRIL_DIR}/common/tools/install/k8s-v${K8S_VER}"
    echo "📁 Path:  $NEW_VER_PATH"

    # Free ports if needed
    ssh $SSH_OPTS -i "$SSH_KEY" "${CN_ROOT_USER}@${host}" bash -s <<<"$FREE_PORTS_SNIPPET" || true

    # Ensure alias IP (only if configured)
    if [[ -n "${INSTALL_IP_ADDR:-}" ]]; then
      if ! ssh $SSH_OPTS -i "$SSH_KEY" "${CN_ROOT_USER}@${host}" bash -s -- "$INSTALL_IP_ADDR" "$INSTALL_IP_IFACE" <<<"$ENSURE_IP_SNIPPET"; then
        echo "⚠️  Failed to ensure $INSTALL_IP_ADDR on $host (attempt $attempt)"
        ((attempt++))
        (( attempt <= INSTALL_RETRY_COUNT )) && { echo "⏳ Waiting ${INSTALL_RETRY_DELAY_SECS}s and retrying..."; sleep "$INSTALL_RETRY_DELAY_SECS"; }
        continue
      fi
    else
      echo "[IP] Skipping ensure; INSTALL_IP_ADDR is empty"
    fi

    # Run installer and verify health
    if ssh $SSH_OPTS -i "$SSH_KEY" "${CN_ROOT_USER}@${host}" bash -s -- "$NEW_VER_PATH" "$K8S_VER" <<<"$RUN_INSTALL_AND_VERIFY_SNIPPET"; then
      echo "✅ Install verified healthy on $host"
      break
    fi

    echo "⚠️  Install attempt $attempt failed on $host"
    ((attempt++))
    if (( attempt <= INSTALL_RETRY_COUNT )); then
      echo "🧹 Performing stronger cleanup (kubeadm reset) before retry..."
      ssh $SSH_OPTS -i "$SSH_KEY" "${CN_ROOT_USER}@${host}" bash -s <<<"$RESET_KUBE_SNIPPET" || true
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
