#!/usr/bin/env bash
# scripts/cluster_install.sh
# Sequential install per server with integrated alias-IP ensure + SSH bootstrap.
# Key enhancements:
# - Ensure alias IP (INSTALL_IP_ADDR) BEFORE SSH bootstrap/installer
# - Runner-side sshpass + ssh-copy-id (no host upgrades), auto-keygen if missing
# - Push key to both host IP and alias IP, with timeouts + fallback
# - Non-interactive apt/dpkg; never upgrade packages

set -euo pipefail

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
: "${INSTALL_IP_ADDR:=10.10.10.20/24}"           # leave empty to skip plumbing
: "${INSTALL_IP_IFACE:=}"
: "${INSTALL_MODE:=}"                             # Fresh_installation / Upgrade_* if Jenkins passed it

# Retries / waits
: "${INSTALL_RETRY_COUNT:=3}"           # attempts per host
: "${INSTALL_RETRY_DELAY_SECS:=20}"     # delay between attempts
: "${BUILD_WAIT_SECS:=300}"             # wait for TRILLIUM tar (fetch may be parallel)

[[ -f "$SSH_KEY" ]] || true
[[ -f "$INSTALL_SERVER_FILE" ]] || { echo "❌ Missing $INSTALL_SERVER_FILE"; exit 1; }

# Non-interactive dpkg/apt (never upgrade)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SVC=l
export UCF_FORCE_CONFFOLD=1

# SSH options from runner to CN
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

# 1) Ensure alias IP exists (robust: try forced iface, default-route iface, then physical NICs)
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

# 2) Ensure ONLY TRILLIUM is extracted under <ROOT>/<BASE>/<TAG>, waiting for a tar if needed
#    On success, ECHO the actual TRILLIUM directory path to stdout (caller captures it).
# $1=root_base_dir (normalized), $2=BASE, $3=TAG, $4=WAIT_SECS
read -r -d '' ENSURE_TRILLIUM_EXTRACTED <<'RS' || true
set -euo pipefail
ROOT="$1"; BASE="$2"; TAG="$3"; WAIT="${4:-0}"
DEST_DIR="$ROOT/$BASE/$TAG"

mkdir -p "$DEST_DIR"
shopt -s nullglob

# ✓ Consider "already extracted" ONLY if a DIRECTORY exists
dir_candidates=( "$DEST_DIR"/TRILLIUM_5GCN_CNF_REL_${BASE}*/ )
if (( ${#dir_candidates[@]} )); then
  # strip trailing slash when echoing
  found_dir="${dir_candidates[0]%/}"
  echo "[TRIL] Found existing dir: ${found_dir}"
  echo "${found_dir}"
  exit 0
fi

# Candidate tars: prefer exact name, then wildcard
exact_tar="$DEST_DIR/TRILLIUM_5GCN_CNF_REL_${BASE}.tar.gz"
wild_tars=( "$DEST_DIR"/TRILLIUM_5GCN_CNF_REL_${BASE}*.tar.gz )

# Wait for tar to appear (exact preferred)
elapsed=0; interval=3; found_tar=""
while :; do
  if [[ -s "$exact_tar" ]]; then found_tar="$exact_tar"; break; fi
  for f in "${wild_tars[@]}"; do
    [[ -s "$f" ]] && { found_tar="$f"; break; }
  done
  [[ -n "$found_tar" || $elapsed -ge $WAIT ]] && break
  echo "[TRIL] Waiting for tar in $DEST_DIR ... (${elapsed}/${WAIT}s)"
  sleep "$interval"; elapsed=$((elapsed+interval))
done

if [[ -z "$found_tar" ]]; then
  echo "[ERROR] No TRILLIUM tar found in $DEST_DIR after ${WAIT}s"; exit 2
fi

# Extract ONLY the chosen tar
echo "[TRIL] Extracting $(basename "$found_tar") into $DEST_DIR ..."
tar -C "$DEST_DIR" -xzf "$found_tar"

# After extraction, find the extracted directory (not the tar)
dir_candidates=( "$DEST_DIR"/TRILLIUM_5GCN_CNF_REL_${BASE}*/ )
if (( ${#dir_candidates[@]} )); then
  found_dir="${dir_candidates[0]%/}"
  echo "[TRIL] Extracted dir: ${found_dir}"
  echo "${found_dir}"
  exit 0
fi

echo "[ERROR] Extraction completed but directory not found under $DEST_DIR"; exit 2
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

# 4) Run installer and verify cluster health (remote)
read -r -d '' RUN_INSTALL_AND_VERIFY_SNIPPET <<'RS' || true
set -euo pipefail
P="$1"; EXP_VER="${2-}"
cd "$P" || { echo "[ERROR] Path not found: $P"; exit 2; }
sed -i 's/\r$//' install_k8s.sh 2>/dev/null || true
echo "[RUN] yes yes | ./install_k8s.sh (in $P)"
set +e
OUT="$(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SVC=l UCF_FORCE_CONFFOLD=1 yes yes | bash ./install_k8s.sh 2>&1)"
RC=$?
set -e
echo "$OUT"
if echo "$OUT" | grep -q 'Permission denied (publickey,password)'; then
  echo "ANSIBLE_SSH_DENIED"; exit 42
fi
export KUBECONFIG=/etc/kubernetes/admin.conf
READY=0; TRIES=30
for _ in $(seq 1 $TRIES); do
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
    if kubectl version --short 2>&1 | grep -q "$EXP_VER"; then echo "[VERIFY] Kubernetes version matches expected: $EXP_VER"; else echo "[WARN] Kubernetes version does not match expected: $EXP_VER"; fi
  fi
  kubectl get pods -A || true
  kubectl get nodes -o wide || true
  exit 0
fi
echo "[VERIFY] Cluster not Ready after install (installer rc=$RC)."; exit 1
RS

any_failed=0

# ---- Runner-side SSH bootstrap (no upgrades, auto-keygen) ----

ensure_sshpass_on_runner() {
  if command -v sshpass >/dev/null 2>&1; then return 0; fi
  echo "[SSH] sshpass not found on runner; installing (no upgrades/no popups)..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo -E apt-get install -yq --no-install-recommends --no-upgrade sshpass || {
      echo "[SSH] ❌ apt install sshpass failed without update; preinstall sshpass or allow a one-time 'apt-get update'." >&2
      return 1
    }
  elif command -v yum >/dev/null 2>&1; then
    sudo -E yum install -y sshpass || return 1
  else
    echo "[SSH] ❌ Unknown package manager on runner." >&2; return 1
  fi
}

ensure_keypair() {
  local key="$1"
  if [[ ! -s "$key" ]]; then
    echo "[SSH] SSH private key not found → generating: $key"
    mkdir -p "$(dirname "$key")"
    ssh-keygen -q -t rsa -N '' -f "$key"
    chmod 600 "$key"
  fi
  [[ -s "${key}.pub" ]] || ssh-keygen -y -f "$key" > "${key}.pub"
}

# copy key with timeout; fallback to raw append
copy_key_to_target() {
  local tgt="$1" pass="$2" pub="$3"
  ssh-keygen -q -R "${tgt}" >/dev/null 2>&1 || true
  echo "[SSH] ssh-copy-id → ${tgt}"
  if timeout 5 sshpass -p "$pass" ssh-copy-id \
      -i "$pub" \
      -o StrictHostKeyChecking=no \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      -o ConnectTimeout=5 -o ConnectionAttempts=1 \
      "root@${tgt}" >/dev/null 2>&1; then
    return 0
  fi
  echo "[SSH] ssh-copy-id timed out/failed; fallback append → ${tgt}"
  timeout 5 sshpass -p "$pass" ssh \
      -o StrictHostKeyChecking=no \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      -o ConnectTimeout=5 -o ConnectionAttempts=1 \
      "root@${tgt}" \
      "umask 077 && mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && printf '%s\n' '$(cat "$pub")' >> ~/.ssh/authorized_keys"
}

key_works_for() {
  local tgt="$1" key="$2"
  timeout 5 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o ConnectionAttempts=1 -i "$key" "root@${tgt}" true 2>/dev/null
}

bootstrap_runner_to_host_and_alias() {
  local host="$1" alias_ip="$2" pass="${3:-root123}" key="$4"
  ensure_sshpass_on_runner || true
  ensure_keypair "$key"

  # Always ensure we can reach the host (often already OK)
  if ! key_works_for "$host" "$key"; then
    copy_key_to_target "$host" "$pass" "${key}.pub" || true
  fi
  if key_works_for "$host" "$key"; then
    echo "[SSH][$host] ✅ Key-based SSH OK (host IP)"
  else
    echo "[SSH][$host] ❌ Key-based SSH still failing (host IP)"; return 1
  fi

  # Alias may be the one Ansible connects to; do it explicitly
  if [[ -n "$alias_ip" ]]; then
    if ! key_works_for "$alias_ip" "$key"; then
      copy_key_to_target "$alias_ip" "$pass" "${key}.pub" || true
    fi
    if key_works_for "$alias_ip" "$key"; then
      echo "[SSH][$host] ✅ Key-based SSH OK (alias $alias_ip)"
    else
      echo "[SSH][$host] ❌ Key-based SSH still failing (alias $alias_ip)"; return 1
    fi
  fi
  return 0
}

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

  # 0) Prepare /mnt on every host (once before attempts)
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s <<<"$PREPARE_MNT_SNIPPET"

  # Normalize ROOT from NEW_BUILD_PATH
  raw_base="$NEW_BUILD_PATH"
  ROOT_BASE="$(normalize_root "$raw_base" "$BASE")"

  # Determine TAG per-host when not provided
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

  # ---- Ensure alias IP FIRST (before any bootstrap/installer) ----
  if [[ -n "${INSTALL_IP_ADDR:-}" ]]; then
    ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$INSTALL_IP_ADDR" "$INSTALL_IP_IFACE" <<<"$ENSURE_IP_SNIPPET" || {
      echo "⚠️  Failed to ensure $INSTALL_IP_ADDR on $host; continuing with best effort..."
    }
  else
    echo "[IP] Skipping ensure; INSTALL_IP_ADDR is empty"
  fi
  ALIAS_ONLY_IP="$(ip_only_from_cidr "$INSTALL_IP_ADDR")"

  # ---- Pre-bootstrap for Fresh installation: ensure keys on host + alias ----
  if [[ "${INSTALL_MODE:-}" == "Fresh_installation" ]]; then
    echo "[SSH][$host] Fresh installation → runner-side key bootstrap (host + alias)"
    bootstrap_runner_to_host_and_alias "$host" "$ALIAS_ONLY_IP" "${CN_BOOTSTRAP_PASS:-root123}" "$SSH_KEY" || true
  fi

  # Attempt loop
  attempt=1
  while (( attempt <= INSTALL_RETRY_COUNT )); do
    echo "🚀 Install attempt $attempt/$INSTALL_RETRY_COUNT on $host"

    # Ensure TRILLIUM present & extracted (waits for tar if fetch is still running)
    TRIL_DIR="$(ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$ROOT_BASE" "$BASE" "$TAG" "$BUILD_WAIT_SECS" <<<"$ENSURE_TRILLIUM_EXTRACTED" | tail -n1 || true)"
    if [[ -z "$TRIL_DIR" ]]; then
      echo "⚠️  TRILLIUM not ready on $host (attempt $attempt)"
      ((attempt++))
      (( attempt <= INSTALL_RETRY_COUNT )) && { echo "⏳ Waiting ${INSTALL_RETRY_DELAY_SECS}s and retrying..."; sleep "$INSTALL_RETRY_DELAY_SECS"; }
      continue
    fi
    NEW_VER_PATH="${TRIL_DIR}/common/tools/install/k8s-v${K8S_VER}"
    echo "📁 Path:  $NEW_VER_PATH"

    # Free ports if needed
    ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s <<<"$FREE_PORTS_SNIPPET" || true

    # Ensure alias IP again (idempotent) in case iface bounced
    if [[ -n "${INSTALL_IP_ADDR:-}" ]]; then
      ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$INSTALL_IP_ADDR" "$INSTALL_IP_IFACE" <<<"$ENSURE_IP_SNIPPET" || true
    fi

    # Run installer and capture output/rc
    RUN_OUT="$(ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$NEW_VER_PATH" "$K8S_VER" <<<"$RUN_INSTALL_AND_VERIFY_SNIPPET" 2>&1 || true)"
    RUN_RC=$?
    echo "$RUN_OUT"

    # If Ansible reported permission denied, force alias bootstrap from runner and retry once
    if [[ $RUN_RC -ne 0 ]] && echo "$RUN_OUT" | grep -q "ANSIBLE_SSH_DENIED"; then
      echo "[SSH][$host] Detected SSH permission error during install. Forcing alias bootstrap and retrying..."
      bootstrap_runner_to_host_and_alias "$host" "$ALIAS_ONLY_IP" "${CN_BOOTSTRAP_PASS:-root123}" "$SSH_KEY" || true
      RUN_OUT="$(ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$NEW_VER_PATH" "$K8S_VER" <<<"$RUN_INSTALL_AND_VERIFY_SNIPPET" 2>&1 || true)"
      RUN_RC=$?
      echo "$RUN_OUT"
    fi

    if [[ $RUN_RC -eq 0 ]]; then
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
