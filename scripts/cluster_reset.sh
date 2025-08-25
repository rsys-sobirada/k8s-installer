#!/usr/bin/env bash
# scripts/cluster_reset.sh
# Takes OLD_BUILD_PATH per-server from server_pci_map.txt (ignores Jenkins UI OLD_BUILD_PATH).
# Flow:
# 1) Ensure alias IP (INSTALL_IP_ADDR) exists on the server
# 2) Verify cluster presence (kubectl nodes/pods)
# 3) Ensure kubespray requirements.txt; if missing, briefly start install_k8s.sh to generate it
# 4) Swap in Jenkins reset.yml + inventory, run uninstall, then restore swaps

set -euo pipefail

# ===== Inputs =====
CR="${CLUSTER_RESET:-Yes}"                         # gate (Yes/True/1 to run)
SSH_KEY="${SSH_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"
SERVER_FILE="${SERVER_FILE:-server_pci_map.txt}"   # lines: name:ip:path  |  ip:path
KSPRAY_DIR="${KSPRAY_DIR:-kubespray-2.27.0}"
K8S_VER="${K8S_VER:-1.31.4}"
OLD_VERSION="${OLD_VERSION:-}"                     # required (e.g., 6.3.0_EA2)
INSTALL_IP_ADDR="${INSTALL_IP_ADDR:-}"             # required (e.g., 10.10.10.20/24)

RESET_YML_WS="${RESET_YML_WS:-$WORKSPACE/reset.yml}"
REQ_WAIT_SECS="${REQ_WAIT_SECS:-360}"
RETRY_COUNT="${RETRY_COUNT:-3}"
RETRY_DELAY_SECS="${RETRY_DELAY_SECS:-10}"
INSTALL_NAME="${INSTALL_NAME:-install_k8s.sh}"
UNINSTALL_NAME="${UNINSTALL_NAME:-uninstall_k8s.sh}"
REL_SUFFIX="${REL_SUFFIX:-}"                       # optional suffix in TRILLIUM dir name

# ===== Gate & validation =====
shopt -s nocasematch
if [[ ! "$CR" =~ ^(yes|true|1)$ ]]; then
  echo "ℹ️  CLUSTER_RESET gate disabled (got '$CR'). Skipping."
  exit 0
fi
shopt -u nocasematch

[[ -f "$SSH_KEY" ]]      || { echo "❌ SSH key not found: $SSH_KEY"; exit 1; }
chmod 600 "$SSH_KEY" || true
[[ -f "$SERVER_FILE" ]]  || { echo "❌ $SERVER_FILE not found"; exit 1; }
[[ -f "$RESET_YML_WS" ]] || { echo "❌ Jenkins reset.yml not found: $RESET_YML_WS"; exit 1; }
[[ -n "$OLD_VERSION" ]]  || { echo "❌ OLD_VERSION is required (e.g. 6.3.0_EA2)"; exit 1; }
[[ -n "$INSTALL_IP_ADDR" ]] || { echo "❌ INSTALL_IP_ADDR is required (e.g. 10.10.10.20/24)"; exit 1; }

# ===== Helpers =====
log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }
ver_num(){ echo "${1%%_*}"; }   # 6.3.0_EA1 -> 6.3.0
ver_tag(){ [[ "$1" == *_* ]] && echo "${1##*_}" || echo ""; }

# Accepts base, versioned, TRILLIUM root, full k8s root, or kubespray dir; returns k8s root
normalize_k8s_path(){
  local base="${1%/}" ver="$2" num tag
  num="$(ver_num "$ver")"; tag="$(ver_tag "$ver")"

  # Full k8s root provided
  if [[ "$base" =~ /common/tools/install/k8s-v[^/]+$ ]]; then
    echo "$base"; return
  fi
  # TRILLIUM root up to common/tools/install provided
  if [[ "$base" =~ /TRILLIUM_5GCN_CNF_REL_${num}[^/]*/common/tools/install$ ]]; then
    echo "$base/k8s-v${K8S_VER}"; return
  fi
  # If pointed at kubespray dir, trim back to k8s root
  if [[ "$base" =~ /common/tools/install/k8s-v[^/]+/kubespray(-[^/]+)?$ ]]; then
    echo "${base%/kubespray*}"; return
  fi
  # Versioned base already ends with /<num> or /<num>/<tag>
  if [[ "$base" =~ /${num}(/${tag})?$ ]]; then
    echo "$base/TRILLIUM_5GCN_CNF_REL_${num}${REL_SUFFIX}/common/tools/install/k8s-v${K8S_VER}"
    return
  fi
  # Plain base: build full hierarchy
  local p="$base/${num}"
  [[ -n "$tag" ]] && p="$p/${tag}"
  echo "$p/TRILLIUM_5GCN_CNF_REL_${num}${REL_SUFFIX}/common/tools/install/k8s-v${K8S_VER}"
}

SSH_OPTS='-o BatchMode=yes -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=5m -o ControlPath=/tmp/ssh_mux_%h_%p_%r'

# Read "ip|path" from server_pci_map.txt (supports name:ip:path or ip:path)
read_server_entries(){
  awk 'NF && $1 !~ /^#/ {
    n=split($0,a,":")
    if(n==3){ printf "%s|%s\n", a[2], a[3] }      # name:ip:path
    else if(n==2){ printf "%s|%s\n", a[1], a[2] } # ip:path
    else { printf "%s|\n", a[1] }                 # ip only (invalid for our logic)
  }' "$SERVER_FILE"
}

remote_file_exists(){
  local ip="$1" p="$2"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail -s -- "$p" <<'EOF'
set -euo pipefail; p="$1"; [[ -e "$p" ]]
EOF
}

remote_cluster_present(){
  local ip="$1"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail <<'EOF'
set +e
if command -v kubectl >/dev/null 2>&1; then
  kubectl get nodes --no-headers 2>/dev/null | grep -q . && exit 0
  kubectl get pods  -A --no-headers 2>/dev/null | grep -q . && exit 0
fi
exit 1
EOF
}

# Ensure alias IP exists on remote host (idempotent)
ensure_alias_ip_remote(){
  local ip="$1"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail -s -- "${INSTALL_IP_ADDR}" <<'EOF'
set -euo pipefail
IP_CIDR="$1"
IFACE="$(ip route | awk "/^default/{print \$5; exit}")"
ip link set "$IFACE" up || true
ip addr replace "$IP_CIDR" dev "$IFACE"
ip -4 addr show dev "$IFACE" | awk "/inet /{print \$2}" | grep -qx "$IP_CIDR"
echo "[alias-ip] ✅ $IP_CIDR on $IFACE"
EOF
}

start_installer_bg(){
  local ip="$1" sp="$2"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail -s -- "$sp" "$INSTALL_NAME" <<'EOF'
set -euo pipefail
SP="$1"; NAME="$2"
cd "$SP"
if [[ -x "./$NAME" || -f "./$NAME" ]]; then
  ( setsid bash -c "yes yes | bash ./$NAME" > install.log 2>&1 & echo $! > install.pid )
  PGID="$(ps -o pgid= -p "$(cat install.pid)" | tr -d ' ')"
  echo "$PGID" > install.pgid
  echo "[START] $NAME pid=$(cat install.pid) pgid=$PGID"
else
  echo "❌ $NAME not found in $(pwd)"; exit 127
fi
EOF
}

stop_installer_pg(){
  local ip="$1" sp="$2"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail -s -- "$sp" <<'EOF'
set +e
SP="$1"; cd "$SP" 2>/dev/null || exit 0
echo "[STOP] Pre-kill:"; pgrep -a -f 'install_k8s.sh|ansible-playbook|kubespray' || true
[[ -f install.pgid ]] && PGID="$(tr -d ' ' < install.pgid 2>/dev/null)" && [[ -n "$PGID" ]] && { kill -TERM -"$PGID" 2>/dev/null; sleep 2; kill -KILL -"$PGID" 2>/dev/null; }
[[ -f install.pid  ]] && PID="$(tr -d ' ' < install.pid  2>/dev/null)" && [[ -n "$PID"  ]] && { kill -TERM "$PID"    2>/dev/null; sleep 2; kill -KILL "$PID"    2>/dev/null; }
pkill -f 'install_k8s.sh' 2>/dev/null || true
pkill -f 'ansible-playbook.*kubespray' 2>/dev/null || true
rm -f install.pid install.pgid 2>/dev/null || true
echo "[STOP] Post-kill:"; pgrep -a -f 'install_k8s.sh|ansible-playbook|kubespray' || true
exit 0
EOF
}

push_reset_override(){
  local ip="$1" sp="$2" swap_id="$3"
  local remote_tmp="/tmp/ci_reset_${swap_id}.yml"
  scp $SSH_OPTS -i "$SSH_KEY" "$RESET_YML_WS" "root@$ip:${remote_tmp}"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail -s -- "$sp" "$KSPRAY_DIR" "$remote_tmp" "$swap_id" <<'EOF'
set -euo pipefail
SP="$1"; KS="$2"; TMP="$3"; ID="$4"
BASE="$SP/$KS"
TGT=""
if [[ -f "$BASE/playbooks/reset.yml" || ! -f "$BASE/reset.yml" ]]; then
  mkdir -p "$BASE/playbooks"; TGT="$BASE/playbooks/reset.yml"
else
  TGT="$BASE/reset.yml"
fi
BK="/tmp/reset_backup_${ID}.yml"; [[ -f "$TGT" ]] && cp -f "$TGT" "$BK" || : > "$BK"
mv -f "$TMP" "$TGT"
CTX="/tmp/reset_swap_ctx_${ID}"; printf "TGT=%s\nBK=%s\n" "$TGT" "$BK" > "$CTX"
echo "[SWAP] reset.yml -> $TGT (backup $BK)"
EOF
}

restore_reset_override(){
  local ip="$1" swap_id="$2"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail -s -- "$swap_id" <<'EOF'
set +e
ID="$1"; CTX="/tmp/reset_swap_ctx_${ID}"; [[ -f "$CTX" ]] || { echo "[RESTORE] reset: no ctx"; exit 0; }
. "$CTX"
mkdir -p "$(dirname "$TGT")"
if [[ -s "$BK" ]]; then mv -f "$BK" "$TGT"; echo "[RESTORE] reset: restored $TGT"; else rm -f "$TGT"; echo "[RESTORE] reset: removed temp"; fi
rm -f "$CTX" 2>/dev/null || true
EOF
}

push_inventory_override(){
  local ip="$1" sp="$2" swap_id="$3"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail -s -- "$sp" "$KSPRAY_DIR" "$swap_id" <<'EOF'
set -euo pipefail
SP="$1"; KS="$2"; ID="$3"
INV_SAMPLE="$SP/$KS/inventory/sample/hosts.yaml"
INV_REAL="$SP/k8s-yamls/hosts.yaml"
[[ -f "$INV_REAL" ]] || { echo "[ERROR] Missing real inventory $INV_REAL"; exit 2; }
mkdir -p "$(dirname "$INV_SAMPLE")"
BK="/tmp/inventory_backup_${ID}.yml"; [[ -f "$INV_SAMPLE" ]] && cp -f "$INV_SAMPLE" "$BK" || : > "$BK"
cp -f "$INV_REAL" "$INV_SAMPLE"
CTX="/tmp/inventory_swap_ctx_${ID}"; printf "INV_SAMPLE=%s\nBK=%s\n" "$INV_SAMPLE" "$BK" > "$CTX"
echo "[SWAP] inventory: $INV_SAMPLE ← $INV_REAL (backup $BK)"
EOF
}

restore_inventory_override(){
  local ip="$1" swap_id="$2"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail -s -- "$swap_id" <<'EOF'
set +e
ID="$1"; CTX="/tmp/inventory_swap_ctx_${ID}"; [[ -f "$CTX" ]] || { echo "[RESTORE] inventory: no ctx"; exit 0; }
. "$CTX"
mkdir -p "$(dirname "$INV_SAMPLE")"
if [[ -s "$BK" ]]; then mv -f "$BK" "$INV_SAMPLE"; echo "[RESTORE] inventory: restored $INV_SAMPLE"; else rm -f "$INV_SAMPLE"; echo "[RESTORE] inventory: removed temp"; fi
rm -f "$CTX" 2>/dev/null || true
EOF
}

run_uninstall_with_retries(){
  local ip="$1" sp="$2"
  local attempt=1
  while (( attempt <= RETRY_COUNT )); do
    echo "🧹 Running $UNINSTALL_NAME on $ip (attempt $attempt/$RETRY_COUNT)..."
    if ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail -s -- "$sp" "$UNINSTALL_NAME" <<'EOF'
set -euo pipefail
SP="$1"; NAME="$2"
cd "$SP"
sed -i 's/\r$//' "$NAME" 2>/dev/null || true
bash -x "./$NAME"
EOF
    then
      echo "✅ Uninstall succeeded on $ip"; return 0
    fi
    echo "⚠️ Uninstall attempt $attempt failed on $ip"
    ((attempt++))
    (( attempt <= RETRY_COUNT )) && { echo "🔁 Retrying in ${RETRY_DELAY_SECS}s..."; sleep "$RETRY_DELAY_SECS"; }
  done
  echo "❌ Uninstall failed after $RETRY_COUNT attempts on $ip"; return 1
}

# ===== Ensure swaps are restored on exit =====
declare -a SWAP_IDS=()   # "<ip>|<id>"
on_exit_restore_all(){
  local item ip id
  for item in "${SWAP_IDS[@]}"; do
    ip="${item%%|*}"; id="${item#*|}"
    restore_reset_override "$ip" "$id" || true
    restore_inventory_override "$ip" "$id" || true
  done
}
trap on_exit_restore_all EXIT

# ===== Main =====
log "Jenkins reset.yml: $RESET_YML_WS"

any_failed=0
while IFS= read -r entry; do
  [[ -n "${entry// }" ]] || continue
  ip="${entry%%|*}"
  pth="${entry#*|}"

  echo ""
  echo "🔧 Server: $ip"

  if [[ -z "$pth" || "$pth" == "$ip" ]]; then
    echo "❌ No OLD_BUILD_PATH specified for $ip in $SERVER_FILE (UI param is ignored by design). Skipping."
    any_failed=1
    continue
  fi

  server_path="$(normalize_k8s_path "$pth" "$OLD_VERSION")"
  echo "📁 Using (normalized): $server_path"

  # 0) Enforce alias IP presence on the node
  ensure_alias_ip_remote "$ip"

  # 1) Pre-check: Kubernetes present?
  if remote_cluster_present "$ip"; then
    echo "✅ Kubernetes detected on $ip — proceeding."
  else
    echo "ℹ️  No Kubernetes detected on $ip — skipping this server."
    continue
  fi

  # 2) Ensure requirements.txt exists (or try to generate via install_k8s.sh)
  req="$server_path/$KSPRAY_DIR/requirements.txt"
  if remote_file_exists "$ip" "$req"; then
    echo "✅ requirements.txt present"
  else
    echo "⏳ requirements.txt not found → starting $INSTALL_NAME in background to generate it"
    start_installer_bg "$ip" "$server_path"

    detected=0; loops=$(( REQ_WAIT_SECS / 2 ))
    for _ in $(seq 1 "$loops"); do
      if remote_file_exists "$ip" "$req"; then
        echo "📄 $req detected → stopping installer"
        stop_installer_pg "$ip" "$server_path"
        detected=1; break
      fi
      sleep 2
    done

    if [[ "$detected" -eq 0 ]]; then
      echo "❌ Timed out waiting for $req on $ip"
      stop_installer_pg "$ip" "$server_path"
      any_failed=1
      continue
    fi
  fi

  # 3) Swap Jenkins reset.yml + inventory; run uninstall; restore
  swap_id="$(date +%s)_$$_$RANDOM"; SWAP_IDS+=("$ip|$swap_id")
  push_reset_override      "$ip" "$server_path" "$swap_id"
  push_inventory_override  "$ip" "$server_path" "$swap_id"

  if ! run_uninstall_with_retries "$ip" "$server_path"; then
    any_failed=1
  fi

  restore_reset_override     "$ip" "$swap_id"
  restore_inventory_override "$ip" "$swap_id"

done < <(read_server_entries)

echo ""
if [[ $any_failed -ne 0 ]]; then
  echo "❌ One or more servers failed."
  exit 1
fi
echo "🎉 Completed all servers successfully."
