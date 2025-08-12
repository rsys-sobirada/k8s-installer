#!/bin/bash
# Orchestrator: requirements.txt wait → kill install PGID → swap Jenkins reset.yml + temp inventory override → run uninstall (3 retries) → restore on exit
# With pre-check (skip if no pods) and abort handler (kill running processes & stop run)

set -euo pipefail

# ---------- Tunables ----------
SSH_KEY="${SSH_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"
SERVER_FILE="${SERVER_FILE:-server_pci_map.txt}"      # name:ip[:custom_k8s_base]
UNINSTALL_NAME="${UNINSTALL_NAME:-uninstall_k8s.sh}"
KSPRAY_DIR="${KSPRAY_DIR:-kubespray-2.27.0}"
K8S_VER="${K8S_VER:-1.31.4}"
REL_SUFFIX="${REL_SUFFIX:-}"
OLD_VERSION="${OLD_VERSION:-}"         # e.g., 6.3.0_EA1 (used if per-server path not provided)
OLD_BUILD_PATH="${OLD_BUILD_PATH:-}"   # e.g., /home/labadmin (used if per-server path not provided)
REQ_WAIT_SECS="${REQ_WAIT_SECS:-360}"
RETRY_COUNT="${RETRY_COUNT:-3}"
RESET_YML_WS="${RESET_YML_WS:-$WORKSPACE/reset.yml}"  # Jenkins-provided reset.yml

# ---------- Basic checks ----------
[[ -f "$SSH_KEY" ]]     || { echo "❌ SSH key not found: $SSH_KEY"; exit 1; }
chmod 600 "$SSH_KEY" || true
[[ -f "$SERVER_FILE" ]] || { echo "❌ $SERVER_FILE not found"; exit 1; }
[[ -f "$RESET_YML_WS" ]]|| { echo "❌ Jenkins reset.yml not found at $RESET_YML_WS"; exit 1; }

# ---------- Path helpers ----------
ver_num(){ echo "${1%%_*}"; }   # 6.3.0_EA1 -> 6.3.0
ver_tag(){ echo "${1##*_}"; }   # 6.3.0_EA1 -> EA1
normalize_k8s_path(){
  local base="${1%/}" ver="$2" num tag
  num="$(ver_num "$ver")"; tag="$(ver_tag "$ver")"
  echo "$base/${num}/${tag}/TRILLIUM_5GCN_CNF_REL_${num}${REL_SUFFIX}/common/tools/install/k8s-v${K8S_VER}"
}

# ---------- Remote helpers ----------
remote_file_exists(){
  local ip="$1" p="$2"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ip" bash -s -- "$p" <<'EOF'
set -euo pipefail; p="$1"; [[ -e "$p" ]]
EOF
}

# Returns 0 if cluster has pods, 1 if no pods / no kubectl / no kubeconfig
remote_cluster_has_pods(){
  local ip="$1"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ip" bash -lc '
set +e
check() { kubectl get pods -A --no-headers 2>/dev/null | grep -q .; }
if ! command -v kubectl >/dev/null 2>&1; then exit 1; fi
check && exit 0
if [[ -r /etc/kubernetes/admin.conf ]]; then export KUBECONFIG=/etc/kubernetes/admin.conf; check && exit 0; fi
exit 1
' >/dev/null
}

start_installer_bg(){
  local ip="$1" sp="$2"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ip" bash -s -- "$sp" <<'REMOTE'
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
REMOTE
}

stop_installer_pg(){
  local ip="$1" sp="$2"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ip" bash -s -- "$sp" <<'REMOTE'
set +e
SP="$1"; cd "$SP" 2>/dev/null || exit 0
echo "[STOP] Pre-kill:"; pgrep -a -f 'install_k8s.sh|ansible-playbook|kubespray' || true
[[ -f install.pgid ]] && PGID="$(tr -d ' ' < install.pgid 2>/dev/null)" && [[ -n "$PGID" ]] && { kill -TERM -"$PGID" 2>/dev/null; sleep 2; kill -KILL -"$PGID" 2>/dev/null; }
[[ -f install.pid  ]] && PID="$(tr -d ' ' < install.pid  2>/dev/null)" && [[ -n "$PID"  ]] && { kill -TERM "$PID"    2>/dev/null; sleep 2; kill -KILL "$PID"    2>/dev/null; }
# Sweep any leftover playbooks spawned by either install or uninstall
pkill -f 'install_k8s.sh' 2>/dev/null || true
pkill -f 'ansible-playbook.*kubespray' 2>/dev/null || true
rm -f install.pid install.pgid 2>/dev/null || true
echo "[STOP] Post-kill:"; pgrep -a -f 'install_k8s.sh|ansible-playbook|kubespray' || true
exit 0
REMOTE
}

# ---------- reset.yml swap with restore ----------
push_reset_override(){
  local ip="$1" sp="$2" swap_id="$3"
  local remote_tmp="/tmp/ci_reset_${swap_id}.yml"
  scp -o StrictHostKeyChecking=no -i "$SSH_KEY" "$RESET_YML_WS" "root@$ip:${remote_tmp}"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ip" bash -s -- "$sp" "$KSPRAY_DIR" "$remote_tmp" "$swap_id" <<'REMOTE'
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
REMOTE
}

restore_reset_override(){
  local ip="$1" swap_id="$2"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ip" bash -s -- "$swap_id" <<'REMOTE'
set +e
ID="$1"; CTX="/tmp/reset_swap_ctx_${ID}"; [[ -f "$CTX" ]] || { echo "[RESTORE] reset: no ctx"; exit 0; }
# shellcheck disable=SC1090
. "$CTX"
mkdir -p "$(dirname "$TGT")"
if [[ -s "$BK" ]]; then mv -f "$BK" "$TGT"; echo "[RESTORE] reset: restored to $TGT"; else rm -f "$TGT"; echo "[RESTORE] reset: removed override"; fi
rm -f "$CTX" 2>/dev/null || true
REMOTE
}

# ---------- inventory override with restore (TEMP COPY, not symlink) ----------
push_inventory_override(){
  local ip="$1" sp="$2" swap_id="$3"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ip" bash -s -- "$sp" "$KSPRAY_DIR" "$swap_id" <<'REMOTE'
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
REMOTE
}

restore_inventory_override(){
  local ip="$1" swap_id="$2"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ip" bash -s -- "$swap_id" <<'REMOTE'
set +e
ID="$1"; CTX="/tmp/inventory_swap_ctx_${ID}"; [[ -f "$CTX" ]] || { echo "[RESTORE] inventory: no ctx"; exit 0; }
# shellcheck disable=SC1090
. "$CTX"
mkdir -p "$(dirname "$INV_SAMPLE")"
if [[ -s "$BK" ]]; then mv -f "$BK" "$INV_SAMPLE"; echo "[RESTORE] inventory: restored $INV_SAMPLE"; else rm -f "$INV_SAMPLE"; echo "[RESTORE] inventory: removed temp"; fi
rm -f "$CTX" 2>/dev/null || true
REMOTE
}

run_uninstall_with_retries(){
  local ip="$1" sp="$2"
  local attempt=1
  while (( attempt <= RETRY_COUNT )); do
    echo "🧹 Running $UNINSTALL_NAME on $ip (attempt $attempt/$RETRY_COUNT)..."
    if ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ip" bash -lc "cd \"$sp\" && sed -i 's/\r$//' \"$UNINSTALL_NAME\" 2>/dev/null || true; cd \"$sp\" && bash -x ./\"$UNINSTALL_NAME\""; then
      echo "✅ Uninstall succeeded on $ip"; return 0
    fi
    echo "⚠️ Uninstall attempt $attempt failed on $ip"; ((attempt++))
    (( attempt <= RETRY_COUNT )) && { echo "🔁 Retrying in 5s..."; sleep 5; }
  done
  echo "❌ Uninstall failed after $RETRY_COUNT attempts on $ip"; return 1
}

# ---------- Abort handler (kill running processes & stop the run) ----------
declare -a SWAP_IDS=()        # "<ip>|<id>"
declare -a SERVER_CTX=()      # "<ip>|<server_path>"
ABORTING=0
on_abort(){
  [[ "$ABORTING" -eq 1 ]] && return
  ABORTING=1
  echo ""
  echo "⚠️  Abort signal received — stopping remote processes and cleaning up..."
  for entry in "${SERVER_CTX[@]}"; do
    ip="${entry%%|*}"; sp="${entry#*|}"
    stop_installer_pg "$ip" "$sp" || true
  done
  # EXIT trap will restore files
  echo "🔚 Exiting due to abort."
  # Use 130 (SIGINT) style code; Jenkins will mark as aborted/failed
  exit 130
}
trap on_abort INT TERM HUP QUIT

# ---------- EXIT trap: always restore swaps ----------
on_exit_restore_all(){
  local item ip id
  for item in "${SWAP_IDS[@]}"; do
    ip="${item%%|*}"; id="${item#*|}"
    restore_reset_override "$ip" "$id" || true
    restore_inventory_override "$ip" "$id" || true
  done
}
trap on_exit_restore_all EXIT

# ---------- Main ----------
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

  # track server context for abort cleanup
  SERVER_CTX+=("$ip|$server_path")

  echo ""
  echo "🔧 Server: $name ($ip)"
  echo "📁 Path:   $server_path"

  # PRE-CHECK: Skip uninstall if no Kubernetes pods found
  if remote_cluster_has_pods "$ip"; then
    echo "✅ Kubernetes detected on $ip (pods present) — proceeding with uninstall."
  else
    echo "ℹ️  No Kubernetes detected on $ip (kubectl missing/invalid context or no pods). Skipping uninstall for this server."
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
    echo "⏳ requirements.txt not found → starting install_k8s.sh in background"
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
