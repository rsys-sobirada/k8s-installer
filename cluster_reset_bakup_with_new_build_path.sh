#!/usr/bin/env bash
# scripts/cluster_reset.sh
# Uses user inputs OLD_VERSION and OLD_BUILD_PATH only (no per-server override).
# Pre-check flow:
# 1) Check kubectl status (nodes or pods)
# 2) Ensure requirements.txt under old build's kubespray; if missing, start install_k8s.sh and monitor
# 3) When requirements.txt appears, kill installer, swap in Jenkins reset.yml + inventory,
#    run ./uninstall_k8s.sh with retries, restore swaps.

set -euo pipefail

# ===== Inputs (from Jenkins parameters) =====
CR="${CLUSTER_RESET:-Yes}"                         # gate (Yes/True/1 to run)
SSH_KEY="${SSH_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"
SERVER_FILE="${SERVER_FILE:-server_pci_map.txt}"   # lines like: name:ip or just ip
KSPRAY_DIR="${KSPRAY_DIR:-kubespray-2.27.0}"
K8S_VER="${K8S_VER:-1.31.4}"

# **MUST come from user input**
OLD_VERSION="${OLD_VERSION:-}"                     # e.g. 6.3.0_EA2 or 6.3.0
OLD_BUILD_PATH="${OLD_BUILD_PATH:-}"               # e.g. /home/labadmin

RESET_YML_WS="${RESET_YML_WS:-$WORKSPACE/reset.yml}"
REQ_WAIT_SECS="${REQ_WAIT_SECS:-360}"
RETRY_COUNT="${RETRY_COUNT:-3}"
RETRY_DELAY_SECS="${RETRY_DELAY_SECS:-10}"
INSTALL_NAME="${INSTALL_NAME:-install_k8s.sh}"
UNINSTALL_NAME="${UNINSTALL_NAME:-uninstall_k8s.sh}"
REL_SUFFIX="${REL_SUFFIX:-}"                       # optional suffix in TRILLIUM dir name (keep default empty)

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
[[ -n "$OLD_VERSION" ]]  || { echo "❌ OLD_VERSION (user input) is required"; exit 1; }
[[ -n "$OLD_BUILD_PATH" ]] || { echo "❌ OLD_BUILD_PATH (user input) is required"; exit 1; }

# ===== Helpers =====
log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }
ver_num(){ echo "${1%%_*}"; }   # 6.3.0_EA1 -> 6.3.0
ver_tag(){ [[ "$1" == *_* ]] && echo "${1##*_}" || echo ""; }

# Build the old build path strictly from user inputs:
# /home/labadmin/6.3.0/EA2/TRILLIUM_5GCN_CNF_REL_6.3.0/common/tools/install/k8s-v1.31.4
normalize_k8s_path(){
  local base="${1%/}" ver="$2" num tag
  num="$(ver_num "$ver")"; tag="$(ver_tag "$ver")"
  local p="$base/${num}"
  [[ -n "$tag" ]] && p="$p/${tag}"
  echo "$p/TRILLIUM_5GCN_CNF_REL_${num}${REL_SUFFIX}/common/tools/install/k8s-v${K8S_VER}"
}

SSH_OPTS='-o BatchMode=yes -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=5m -o ControlPath=/tmp/ssh_mux_%h_%p_%r'

read_ips(){
  awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){n=split($0,a,":"); print a[2]} else {print $1} }' "$SERVER_FILE"
}

remote_file_exists(){
  local ip="$1" p="$2"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail -s -- "$p" <<'EOF'
set -euo pipefail; p="$1"; [[ -e "$p" ]]
EOF
}

# 1) Pre-check: kubectl nodes or pods
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

# Swap Jenkins reset.yml into kubespray (with restore)
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

# Copy real inventory into kubespray sample (with restore)
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
server_path="$(normalize_k8s_path "$OLD_BUILD_PATH" "$OLD_VERSION")"   # ← from user inputs
echo "📁 Old build path (user input): $server_path"

any_failed=0
while IFS= read -r ip; do
  [[ -n "${ip// }" ]] || continue

  echo ""
  echo "🔧 Server: $ip"
  echo "📁 Using:  $server_path"

  # 1) Pre-check: kubectl available & reports nodes or pods
  if remote_cluster_present "$ip"; then
    echo "✅ Kubernetes detected on $ip — proceeding."
  else
    echo "ℹ️  No Kubernetes detected on $ip — skipping this server."
    continue
  fi

  req="$server_path/$KSPRAY_DIR/requirements.txt"

  # 2) Ensure requirements.txt; if missing, start install and monitor
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

done < <(read_ips)

echo ""
if [[ $any_failed -ne 0 ]]; then
  echo "❌ One or more servers failed."
  exit 1
fi
echo "🎉 Completed all servers successfully."
