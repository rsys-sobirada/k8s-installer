#!/bin/bash
# scripts/cluster_reset.sh
# Uninstall/reset on each CN node, only if CLUSTER_RESET is enabled.
# - Detects existing clusters via kube ports (6443/10257) OR kubectl pods
# - Swaps in Jenkins reset.yml and inventory (with restore)
# - Uninstall with retries + delay; frees kube ports before/after each try
# - SSH key auth to root@<ip>

set -euo pipefail

# ---- Gate ----
CR="${CLUSTER_RESET:-No}"
shopt -s nocasematch
if [[ ! "$CR" =~ ^(yes|true|1)$ ]]; then
  echo "ℹ️  CLUSTER_RESET disabled (got '$CR'). Skipping."
  exit 0
fi
shopt -u nocasematch

# ---- Inputs ----
SSH_KEY="${SSH_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"
SERVER_FILE="${SERVER_FILE:-server_pci_map.txt}"     # name:ip[:custom_k8s_base]
UNINSTALL_NAME="${UNINSTALL_NAME:-uninstall_k8s.sh}"
KSPRAY_DIR="${KSPRAY_DIR:-kubespray-2.27.0}"
K8S_VER="${K8S_VER:-1.31.4}"
REL_SUFFIX="${REL_SUFFIX:-}"
OLD_VERSION="${OLD_VERSION:-}"          # e.g. 6.3.0_EA1
OLD_BUILD_PATH="${OLD_BUILD_PATH:-}"    # e.g. /home/labadmin
REQ_WAIT_SECS="${REQ_WAIT_SECS:-360}"
RETRY_COUNT="${RETRY_COUNT:-3}"
RETRY_DELAY_SECS="${RETRY_DELAY_SECS:-10}"   # delay between retries
RESET_YML_WS="${RESET_YML_WS:-$WORKSPACE/reset.yml}"

[[ -f "$SSH_KEY" ]]     || { echo "❌ SSH key not found: $SSH_KEY"; exit 1; }
chmod 600 "$SSH_KEY" || true
[[ -f "$SERVER_FILE" ]] || { echo "❌ $SERVER_FILE not found"; exit 1; }
[[ -f "$RESET_YML_WS" ]]|| { echo "❌ Jenkins reset.yml not found at $RESET_YML_WS"; exit 1; }

# ---- Helpers ----
ver_num(){ echo "${1%%_*}"; }   # 6.3.0_EA1 -> 6.3.0
ver_tag(){ echo "${1##*_}"; }   # 6.3.0_EA1 -> EA1
normalize_k8s_path(){
  local base="${1%/}" ver="$2" num tag
  num="$(ver_num "$ver")"; tag="$(ver_tag "$ver")"
  echo "$base/${num}/${tag}/TRILLIUM_5GCN_CNF_REL_${num}${REL_SUFFIX}/common/tools/install/k8s-v${K8S_VER}"
}

SSH_OPTS='-o BatchMode=yes -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=5m -o ControlPath=/tmp/ssh_mux_%h_%p_%r'

# ---- Remote helpers ----
remote_file_exists(){
  local ip="$1" p="$2"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -s -- "$p" <<'EOF'
set -euo pipefail; p="$1"; [[ -e "$p" ]]
EOF
}

remote_cluster_present(){
  local ip="$1"
  # 1) Ports check
  if ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" 'ss -ltn | egrep -q ":(6443|10257)\s"'; then
    return 0
  fi
  # 2) kubectl check
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -s <<'EOF' >/dev/null
set +e
check(){ kubectl get pods -A --no-headers 2>/dev/null | grep -q .; }
if command -v kubectl >/dev/null 2>&1; then
  check && exit 0
  if [[ -r /etc/kubernetes/admin.conf ]]; then export KUBECONFIG=/etc/kubernetes/admin.conf; check && exit 0; fi
fi
exit 1
EOF
}

force_free_kube_ports(){
  local ip="$1"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -s <<'EOF'
set -euo pipefail
systemctl stop kubelet || true
rm -f /etc/kubernetes/manifests/*.yaml || true
pkill -f 'kube-apiserver|kube-controller-manager|kube-scheduler' 2>/dev/null || true
if command -v crictl >/dev/null 2>&1; then
  crictl ps -a | awk '/kube-apiserver|kube-controller-manager|kube-scheduler/{print $1}' | xargs -r crictl rm -f
fi
EOF
}

start_installer_bg(){
  local ip="$1" sp="$2"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -s -- "$sp" <<'EOF'
set -euo pipefail
SP="$1"; cd "$SP"
if [[ -x ./install_k8s.sh || -f ./install_k8s.sh ]]; then
  ( setsid bash -c 'yes yes | bash ./install_k8s.sh' > install.log 2>&1 & echo $! > install.pid )
  PGID="$(ps -o pgid= -p "$(cat install.pid)" | tr -d ' ')"
  echo "$PGID" > install.pgid
  echo "[START] install_k8s.sh pid=$(cat install.pid) pgid=$PGID"
else
  echo "❌ install_k8s.sh not found in $(pwd)"; exit 127
fi
EOF
}

stop_installer_pg(){
  local ip="$1" sp="$2"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -s -- "$sp" <<'EOF'
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
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -s -- "$sp" "$KSPRAY_DIR" "$remote_tmp" "$swap_id" <<'EOF'
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
echo "[SWAP] Using $TGT; backup at $BK; ctx $CTX"
EOF
}

restore_reset_override(){
  local ip="$1" swap_id="$2"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -s -- "$swap_id" <<'EOF'
set +e
ID="$1"; CTX="/tmp/reset_swap_ctx_${ID}"; [[ -f "$CTX" ]] || { echo "[RESTORE] reset: no ctx"; exit 0; }
. "$CTX"
mkdir -p "$(dirname "$TGT")"
if [[ -s "$BK" ]]; then mv -f "$BK" "$TGT"; echo "[RESTORE] reset: restored to $TGT"; else rm -f "$TGT"; echo "[RESTORE] reset: removed override"; fi
rm -f "$CTX" 2>/dev/null || true
EOF
}

push_inventory_override(){
  local ip="$1" sp="$2" swap_id="$3"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -s -- "$sp" "$KSPRAY_DIR" "$swap_id" <<'EOF'
set -euo pipefail
SP="$1"; KS="$2"; ID="$3"
INV_SAMPLE="$SP/$KS/inventory/sample/hosts.yaml"
INV_REAL="$SP/k8s-yamls/hosts.yaml"
[[ -f "$INV_REAL" ]] || { echo "[ERROR] Missing real inventory $INV_REAL"; exit 2; }
mkdir -p "$(dirname "$INV_SAMPLE")"
BK="/tmp/inventory_backup_${ID}.yml"; [[ -f "$INV_SAMPLE" ]] && cp -f "$INV_SAMPLE" "$BK" || : > "$BK"
cp -f "$INV_REAL" "$INV_SAMPLE"
CTX="/tmp/inventory_swap_ctx_${ID}"; printf "INV_SAMPLE=%s\nBK=%s\n" "$INV_SAMPLE" "$BK" > "$CTX"
echo "[SWAP] inventory: $INV_SAMPLE ← $INV_REAL; backup at $BK; ctx $CTX"
EOF
}

restore_inventory_override(){
  local ip="$1" swap_id="$2"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -s -- "$swap_id" <<'EOF'
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
    force_free_kube_ports "$ip" || true
    if ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -s -- "$sp" "$UNINSTALL_NAME" <<'EOF'
set -euo pipefail
SP="$1"; NAME="$2"
cd "$SP"
sed -i 's/\r$//' "$NAME" 2>/dev/null || true
bash -x "./$NAME"
EOF
    then
      force_free_kube_ports "$ip" || true
      echo "✅ Uninstall succeeded on $ip"; return 0
    fi
    echo "⚠️ Uninstall attempt $attempt failed on $ip"
    ((attempt++))
    (( attempt <= RETRY_COUNT )) && { echo "🔁 Retrying in ${RETRY_DELAY_SECS}s..."; sleep "$RETRY_DELAY_SECS"; }
  done
  echo "❌ Uninstall failed after $RETRY_COUNT attempts on $ip"; return 1
}

# ---- Traps ----
declare -a SWAP_IDS=()        # "<ip>|<id>"
declare -a SERVER_CTX=()      # "<ip>|<server_path>"
ABORTING=0
on_abort(){
  [[ "$ABORTING" -eq 1 ]] && return
  ABORTING=1
  echo ""
  echo "⚠️  Abort signal — stopping remote processes and cleaning up..."
  for entry in "${SERVER_CTX[@]}"; do
    ip="${entry%%|*}"; sp="${entry#*|}"
    stop_installer_pg "$ip" "$sp" || true
  done
  echo "🔚 Exiting due to abort."
  exit 130
}
trap on_abort INT TERM HUP QUIT

on_exit_restore_all(){
  local item ip id
  for item in "${SWAP_IDS[@]}"; do
    ip="${item%%|*}"; id="${item#*|}"
    restore_reset_override "$ip" "$id" || true
    restore_inventory_override "$ip" "$id" || true
  done
}
trap on_exit_restore_all EXIT

# ---- Main ----
echo "Jenkins reset.yml: $RESET_YML_WS"
any_failed=0

while IFS=':' read -r name ip maybe_path || [[ -n "${name:-}" ]]; do
  [[ -z "${name// }" ]] && continue
  [[ "${name:0:1}" == "#" ]] && continue

  if [[ -n "${maybe_path:-}" ]]; then
    server_path="${maybe_path%/}"
  else
    if [[ -z "${OLD_BUILD_PATH:-}" || -z "${OLD_VERSION:-}" ]]; then
      echo "❌ $name ($ip): no path provided and OLD_BUILD_PATH/OLD_VERSION not set"
      any_failed=1; continue
    fi
    server_path="$(normalize_k8s_path "$OLD_BUILD_PATH" "$OLD_VERSION")"
  fi
  SERVER_CTX+=("$ip|$server_path")

  echo ""
  echo "🔧 Server: $name ($ip)"
  echo "📁 Path:   $server_path"

  if remote_cluster_present "$ip"; then
    echo "✅ Kubernetes detected on $ip — proceeding with uninstall."
  else
    echo "ℹ️  No Kubernetes detected on $ip. Skipping uninstall for this server."
    continue
  fi

  req="$server_path/$KSPRAY_DIR/requirements.txt"
  if remote_file_exists "$ip" "$req"; then
    echo "✅ requirements.txt present"
    swap_id="$(date +%s)_$$_$RANDOM"; SWAP_IDS+=("$ip|$swap_id")
    push_reset_override      "$ip" "$server_path" "$swap_id"
    push_inventory_override  "$ip" "$server_path" "$swap_id"
    run_uninstall_with_retries "$ip" "$server_path" || any_failed=1
    restore_reset_override     "$ip" "$swap_id"
    restore_inventory_override "$ip" "$swap_id"
  else
    echo "⏳ requirements.txt not found → starting install_k8s.sh in background to generate it"
    start_installer_bg "$ip" "$server_path"

    detected=0; loops=$(( REQ_WAIT_SECS / 2 ))
    for _ in $(seq 1 "$loops"); do
      if remote_file_exists "$ip" "$req"; then
        echo "📄 $req detected → stopping installer"
        stop_installer_pg "$ip" "$server_path"
        swap_id="$(date +%s)_$$_$RANDOM"; SWAP_IDS+=("$ip|$swap_id")
        push_reset_override      "$ip" "$server_path" "$swap_id"
        push_inventory_override  "$ip" "$server_path" "$swap_id"
        run_uninstall_with_retries "$ip" "$server_path" || any_failed=1
        restore_reset_override     "$ip" "$swap_id"
        restore_inventory_override "$ip" "$swap_id"
        detected=1; break
      fi
      sleep 2
    done

    if [[ "$detected" -eq 0 ]]; then
      echo "❌ Timed out waiting for $req on $ip"
      stop_installer_pg "$ip" "$server_path"
      any_failed=1
    fi
  fi
done < "$SERVER_FILE"

echo ""
if [[ $any_failed -ne 0 ]]; then
  echo "❌ One or more servers failed."
  exit 1
fi
echo "🎉 Completed all servers successfully."
