#!/usr/bin/env bash
# scripts/cluster_reset.sh
# Takes OLD_BUILD_PATH per-server from server_pci_map.txt (ignores UI OLD_BUILD_PATH).
# Flow:
# 1) Detect Kubernetes on host
# 2) Ensure requirements.txt under old build's kubespray; if missing, start install_k8s.sh and monitor
# 3) When requirements.txt appears, stop installer, swap in Jenkins reset.yml + inventory,

UNINSTALL="${server_path}/uninstall_k8s.sh"
echo "🧹 Running uninstall_k8s.sh on ${ip} (attempt ${tries}/${RETRY_COUNT})..."

ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${HOST_USER:-root}@${ip}" bash -lc "
  set -euo pipefail
  if [ ! -f '${UNINSTALL}' ]; then
    echo '[reset] ❌ Not found: ${UNINSTALL}'; exit 2
  fi
  # strip CRLF just in case and ensure executable
  sed -i 's/\r$//' '${UNINSTALL}' || true
  chmod +x '${UNINSTALL}'
  # force bash to avoid /bin/sh parsing errors
  bash '${UNINSTALL}'
"



#    run ./uninstall_k8s.sh with retries; restore swaps.

set -euo pipefail

# ===== Inputs =====
CR="${CLUSTER_RESET:-Yes}"                         # gate (Yes/True/1 to run)
SSH_KEY="${SSH_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"
SERVER_FILE="${SERVER_FILE:-server_pci_map.txt}"   # lines: name:ip:path  |  ip:path
KSPRAY_DIR="${KSPRAY_DIR:-kubespray-2.27.0}"
K8S_VER="${K8S_VER:-1.31.4}"
OLD_VERSION="${OLD_VERSION:-}"                     # e.g. 6.3.0_EA2 or 6.3.0

RESET_YML_WS="${RESET_YML_WS:-$WORKSPACE/reset.yml}"
REQ_WAIT_SECS="${REQ_WAIT_SECS:-360}"
RETRY_COUNT="${RETRY_COUNT:-3}"
RETRY_DELAY_SECS="${RETRY_DELAY_SECS:-10}"
INSTALL_NAME="${INSTALL_NAME:-install_k8s.sh}"
UNINSTALL_NAME="${UNINSTALL_NAME:-uninstall_k8s.sh}"
REL_SUFFIX="${REL_SUFFIX:-}"                       # optional suffix in TRILLIUM dir name

# Optional inputs for alias IP ensure (same semantics as install)
: "${INSTALL_IP_ADDR:=}"                           # e.g. 10.10.10.20/24 ; if empty, skipped
: "${INSTALL_IP_IFACE:=}"                          # optional explicit iface

# ---- NEW (IP Monitor) ----
IP_MONITOR_INTERVAL="${IP_MONITOR_INTERVAL:-30}"   # seconds between checks

# ===== Gate & validation =====
shopt -s nocasematch
if [[ ! "$CR" =~ ^(yes|true|1)$ ]]; then
  echo ℹ️  CLUSTER_RESET gate disabled (got '$CR'). Skipping."
  exit 0
fi
shopt -u nocasematch

[[ -f "$SSH_KEY" ]]      || { echo "❌ SSH key not found: $SSH_KEY"; exit 1; }
chmod 600 "$SSH_KEY" || true
[[ -f "$SERVER_FILE" ]]  || { echo "❌ $SERVER_FILE not found"; exit 1; }
[[ -f "$RESET_YML_WS" ]] || { echo "❌ Jenkins reset.yml not found: $RESET_YML_WS"; exit 1; }
[[ -n "$OLD_VERSION" ]]  || { echo "❌ OLD_VERSION is required (e.g. 6.3.0_EA2)"; exit 1; }

# ===== Helpers =====
log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }
ver_num(){ echo "${1%%_*}"; }   # 6.3.0_EA1 -> 6.3.0
ver_tag(){ [[ "$1" == *_* ]] && echo "${1##*_}" || echo ""; }

SSH_OPTS='-o BatchMode=yes -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=5m -o ControlPath=/tmp/ssh_mux_%h_%p_%r'

# Version-safe path normalizer (prevents double-versioning; probes EA/non-EA)
normalize_k8s_path() {
  local base="${1%/}" old_ver="$2"

  # 1) Already a full k8s root → return as-is
  if [[ "$base" =~ /common/tools/install/k8s-v[^/]+$ ]]; then
    echo "$base"; return
  fi

  # 2) Already at TRILLIUM install dir → just add k8s-v
  if [[ "$base" =~ /TRILLIUM_5GCN_CNF_REL_[0-9]+\.[0-9]+\.[0-9]+[^/]*/common/tools/install$ ]]; then
    echo "$base/k8s-v${K8S_VER}"; return
  fi

  # 3) If base ends with ".../<num>[/EAx]" use version/tag from path and PROBE remote
  if [[ "$base" =~ /([0-9]+\.[0-9]+\.[0-9]+)(/(EA[0-9]+))?$ ]]; then
    local num_in_path tag_in_path rel_with rel_without
    num_in_path="$(printf '%s\n' "$base" | sed -n 's#.*/\([0-9]\+\.[0-9]\+\.[0-9]\+\)\(/\(EA[0-9]\+\)\)\?$#\1#p')"
    tag_in_path="$(printf '%s\n' "$base" | sed -n 's#.*/[0-9]\+\.[0-9]\+\.[0-9]\+\(/\(EA[0-9]\+\)\)\?$#\2#p' | sed 's#^/##')"

    rel_with="TRILLIUM_5GCN_CNF_REL_${num_in_path}${tag_in_path:+_${tag_in_path}}"
    rel_without="TRILLIUM_5GCN_CNF_REL_${num_in_path}"

    local cand_with="$base/${rel_with}/common/tools/install/k8s-v${K8S_VER}"
    local cand_wo="$base/${rel_without}/common/tools/install/k8s-v${K8S_VER}"

    if ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" test -d "$cand_with"; then
      echo "$cand_with"; return
    elif ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" test -d "$cand_wo"; then
      echo "$cand_wo"; return
    else
      echo "$cand_wo"; return
    fi
  fi

  # 4) If base ends right at ".../common/tools/install" without k8s-v
  if [[ "$base" =~ /common/tools/install$ ]]; then
    echo "$base/k8s-v${K8S_VER}"; return
  fi

  # 5) Fallback: use OLD_VERSION to build under base, then probe both TRILLIUM variants
  local num tag rel_with rel_without parent cand_with cand_wo
  num="${old_ver%%_*}"
  tag=""; [[ "$old_ver" == *_* ]] && tag="${old_ver##*_}"
  rel_with="TRILLIUM_5GCN_CNF_REL_${num}${tag:+_${tag}}"
  rel_without="TRILLIUM_5GCN_CNF_REL_${num}"

  parent="$base/${num}${tag:+/${tag}}"
  cand_with="$parent/${rel_with}/common/tools/install/k8s-v${K8S_VER}"
  cand_wo="$parent/${rel_without}/common/tools/install/k8s-v${K8S_VER}"

  if ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" test -d "$cand_with"; then
    echo "$cand_with"
  elif ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" test -d "$cand_wo"; then
    echo "$cand_wo"
  else
    echo "$cand_wo"
  fi
}

# Robust alias-IP ensure snippet (present → no-op; missing → add)
read -r -d '' ENSURE_IP_SNIPPET <<'RS' || true
set -euo pipefail
IP_CIDR="$1"; FORCE_IFACE="${2-}"
IP_ONLY="${IP_CIDR%%/*}"
is_present(){ ip -4 addr show | awk '/inet /{print $2}' | cut -d/ -f1 | grep -qx "$IP_ONLY"; }
echo "[IP] Ensuring ${IP_CIDR}"
if is_present; then
  echo "[IP] Already present: ${IP_ONLY}"
  exit 0
fi
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
    ip -4 addr show dev "$IF" | awk '/inet /{print $2}' | cut -d/ -f1 | grep -qx "$IP_ONLY" && { echo "[IP] OK on ${IF}"; exit 0; }
  fi
done
echo "[IP] ERROR: Could not plumb ${IP_CIDR} (tried: ${CAND[*]})"
exit 2
RS

# Read "ip|path" from server_pci_map.txt (supports name:ip:path or ip:path)
read_server_entries(){
  awk 'NF && $1 !~ /^#/ {
    gsub(/\r/,"");           # strip Windows CRs
    sub(/[[:space:]]+$/,""); # strip trailing whitespace
    n=split($0,a,":")
    if(n==3){ printf "%s|%s\n", a[2], a[3] }      # name:ip:path
    else if(n==2){ printf "%s|%s\n", a[1], a[2] } # ip:path
    else { printf "%s|\n", a[1] }                 # ip only (no path)
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
    if ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail -s -- "$sp" "$UNINSTALL_NAME" "${INSTALL_IP_ADDR:-}" "${INSTALL_IP_IFACE:-}" "${IP_MONITOR_INTERVAL:-30}" <<'EOF'
set -euo pipefail
SP="$1"; NAME="$2"; CIDR="\${3:-}"; IFACE_PIN="\${4:-}"; INTERVAL="\${5:-30}"
cd "$SP"
sed -i 's/\r$//' "$NAME" 2>/dev/null || true

# ---- Inline alias IP watchdog (keeps INSTALL_IP_ADDR present during uninstall) ----
if [[ -n "\${CIDR:-}" ]]; then
  IP="\${CIDR%%/*}"
  LOG="/var/log/alias_ipmon.log"

  ipmon_log(){ printf '[%(%F %T)T] [IPMON] %s\n' -1 "$*" >>"$LOG"; }
  is_present(){ ip -4 addr show | awk '/inet /{print \$2}' | cut -d/ -f1 | grep -qx "$IP"; }
  pick_if(){
    if [[ -n "$IFACE_PIN" ]]; then echo "$IFACE_PIN"; return; fi
    local d; d=\$(ip route 2>/dev/null | awk '/^default/{print \$5; exit}')
    [[ -n "\$d" ]] && { echo "\$d"; return; }
    ip -o link | awk -F': ' '{print \$2}' | sed 's/@.*//' \
      | grep -E '^(en|eth|ens|eno|em|bond|br)' \
      | grep -Ev '(^lo$|docker|podman|cni|flannel|cilium|calico|weave|veth|tun|tap|virbr|wg)' | head -n1
  }
  ensure_once(){
    local IF; IF="\$(pick_if)"; [[ -n "\$IF" ]] || { ipmon_log "no iface"; return 1; }
    ip link set dev "\$IF" up || true
    if ip addr replace "$CIDR" dev "\$IF" 2>/tmp/ipmon_err.log; then
      sleep 1; is_present && { ipmon_log "ensured $CIDR on \$IF"; return 0; }
    fi
    ipmon_log "failed to add $CIDR on \$IF: \$(tr -d \\n </tmp/ipmon_err.log 2>/dev/null || true)"; return 1
  }

  mkdir -p "/var/log" 2>/dev/null || true; : >>"\$LOG" || true
  ipmon_log "inline watch start for $CIDR (iface=\${IFACE_PIN:-auto}, interval=\${INTERVAL}s)"
  ! is_present && ensure_once || true

  # reactive watcher
  if command -v ip >/dev/null 2>&1; then
    ( ip monitor address 2>/dev/null | while read -r _; do
        ! is_present && { ipmon_log "addr change; restoring $CIDR"; ensure_once || true; }
      done ) &
    MON_PID=\$!
    trap '[[ -n "\${MON_PID:-}" ]] && kill "\$MON_PID" 2>/dev/null || true' EXIT
  fi

  # periodic safety loop
  ( while true; do
      ! is_present && { ipmon_log "periodic restore; adding $CIDR"; ensure_once || true; }
      sleep "\$INTERVAL"
    done ) &
fi
# ---- end inline watchdog ----

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

# ===== NEW: IP monitor helpers (start/stop, hardened & logged) =====
declare -a IP_MON_IDS=()  # "<ip>|<tag>"

start_ip_monitor(){
  local ip="$1" ip_cidr="$2" iface="$3"
  [[ -z "$ip_cidr" ]] && { echo "[IPMON][$ip] skipped (INSTALL_IP_ADDR empty)"; return 0; }

  # Stable one-per-host+CIDR tag
  local cidr_sanitized="${ip_cidr//\//_}"               # e.g. 10.10.10.20_24
  local tag="ipmon_${ip//./-}_${cidr_sanitized}"
  IP_MON_IDS+=("$ip|$tag")

  local remote="/tmp/${tag}"
  local sh="${remote}.sh"
  local pidf="${remote}.pid"
  local pgf="${remote}.pgid"
  local log="/var/log/alias_ipmon.log"

  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -eo pipefail -s -- \
      "${ip_cidr:-}" "${iface:-}" "${IP_MONITOR_INTERVAL:-30}" \
      "${sh:-}" "${pidf:-}" "${pgf:-}" "${log:-/var/log/alias_ipmon.log}" <<'EOF'
CIDR="${1:-}"; IFACE="${2:-}"; SLEEP_SEC="${3:-30}"
SH="${4:-/tmp/ipmon.sh}"; PIDF="${5:-/tmp/ipmon.pid}"; PGF="${6:-/tmp/ipmon.pgid}"
LOG_PATH="${7:-/var/log/alias_ipmon.log}"
IP="${CIDR%%/*}"

# ensure log file usable
if ! { mkdir -p "$(dirname "$LOG_PATH")" 2>/dev/null && : >>"$LOG_PATH"; }; then
  LOG_PATH="/tmp/alias_ipmon.log"
  mkdir -p /tmp >/dev/null 2>&1 || true
  : >>"$LOG_PATH" || true
fi

ipmon_log(){ printf '[%(%F %T)T] [IPMON] %s\n' -1 "$*" >>"$LOG_PATH"; }

# If already running, keep it
if [[ -s "$PIDF" ]] && ps -p "$(cat "$PIDF" 2>/dev/null)" >/dev/null 2>&1; then
  ipmon_log "already running (PID=$(cat "$PIDF")) logging to $LOG_PATH"
  exit 0
fi

cat >"$SH" <<'MON'
#!/usr/bin/env bash
set -euo pipefail
CIDR="$1"; IFACE="${2:-}"; SLEEP_SEC="${3:-30}"; LOG_PATH="$4"
IP="${CIDR%%/*}"

ipmon_log(){ printf '[%(%F %T)T] [IPMON] %s\n' -1 "$*" >>"$LOG_PATH"; }

is_present(){ ip -4 addr show | awk "/inet /{print \$2}" | cut -d/ -f1 | grep -qx "$IP"; }

pick_if(){
  [[ -n "$IFACE" ]] && { echo "$IFACE"; return; }
  DEFIF=$(ip route 2>/dev/null | awk "/^default/{print \$5; exit}" || true)
  if [[ -n "$DEFIF" ]]; then echo "$DEFIF"; return; fi
  ip -o link | awk -F': ' '{print $2}' \
    | sed 's/@.*//' \
    | grep -E '^(en|eth|ens|eno|em|bond|br)' \
    | grep -Ev '(^lo$|docker|podman|cni|flannel|cilium|calico|weave|veth|tun|tap|virbr|wg)' \
    | head -n1
}

ensure_once(){
  local IF
  IF="$(pick_if)"
  if [[ -z "$IF" ]]; then ipmon_log "no suitable iface"; return 1; fi
  ip link set dev "$IF" up || true
  if ip addr replace "$CIDR" dev "$IF" 2>/tmp/ipmon_err.log; then
    sleep 1
    if is_present; then
      ipmon_log "added $CIDR on $IF"
      return 0
    fi
  fi
  local ERR="$(tr -d '\n' </tmp/ipmon_err.log 2>/dev/null || true)"
  ipmon_log "failed to add $CIDR on $IF: ${ERR:-unknown}"
  return 1
}

ipmon_log "watchdog start for $CIDR (IFACE=${IFACE:-auto})"

# Ensure once at start
if ! is_present; then
  ensure_once || true
fi

# React to address changes immediately
if command -v ip >/dev/null 2>&1; then
  (
    ip monitor address 2>/dev/null | while read -r _; do
      if ! is_present; then
        ipmon_log "detected address change; re-adding $CIDR"
        ensure_once || true
      fi
    done
  ) &
fi

# Periodic safety check
while true; do
  if ! is_present; then
    ipmon_log "missing; re-adding $CIDR"
    ensure_once || true
  fi
  sleep "$SLEEP_SEC"
done
MON
chmod +x "$SH"

# Launch detached; persist beyond SSH session; record PID+PGID
nohup setsid bash -lc "bash '$SH' '$CIDR' '${IFACE:-}' '$SLEEP_SEC' '$LOG_PATH'" >/dev/null 2>&1 &
echo $! >"$PIDF"
PGID="$(ps -o pgid= -p "$(cat "$PIDF")" | tr -d ' ')"
echo "$PGID" >"$PGF"
ipmon_log "started PID=$(cat "$PIDF") PGID=$PGID → $LOG_PATH"
EOF
}


stop_ip_monitor(){
  local ip="$1" tag="$2"
  local remote="/tmp/${tag}"; local pidf="${remote}.pid"; local pgf="${remote}.pgid"; local sh="${remote}.sh"
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail -s -- "$pidf" "$pgf" "$sh" <<'EOF'
set +e
PIDF="${1:?}"; PGF="${2:?}"; SH="${3:?}"
if [[ -f "$PGF" ]]; then
  PGID="$(tr -d ' ' < "$PGF" 2>/dev/null)"
  [[ -n "$PGID" ]] && { kill -TERM -"$PGID" 2>/dev/null; sleep 1; kill -KILL -"$PGID" 2>/dev/null; }
fi
[[ -f "$PIDF" ]] && { kill -TERM "$(cat "$PIDF")" 2>/dev/null; sleep 1; kill -KILL "$(cat "$PIDF")" 2>/dev/null; }
rm -f "$PGF" "$PIDF" "$SH" 2>/dev/null || true
echo "[IPMON] stopped"
EOF
}

# ===== Ensure swaps are restored & monitors stopped on exit =====
declare -a SWAP_IDS=()   # "<ip>|<id>"
on_exit_restore_all(){
  local item ip id
  for item in "${SWAP_IDS[@]}"; do
    ip="${item%%|*}"; id="${item#*|}"
    restore_reset_override "$ip" "$id" || true
    restore_inventory_override "$ip" "$id" || true
  done
}
on_exit_stop_ipmon(){
  local item ip tag
  for item in "${IP_MON_IDS[@]}"; do
    ip="${item%%|*}"; tag="${item#*|}"
    stop_ip_monitor "$ip" "$tag" || true
  done
}
trap 'on_exit_restore_all; on_exit_stop_ipmon' EXIT

# ===== Main =====
log "Jenkins reset.yml: $RESET_YML_WS"

any_failed=0
while IFS= read -r entry; do
  [[ -n "${entry// }" ]] || continue
  ip="${entry%%|*}"
  pth="${entry#*|}"

  echo ""
  echo "🔧 Server: $ip"

  # Ensure alias IP (only if configured)
  if [[ -n "${INSTALL_IP_ADDR:-}" ]]; then
    ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -s -- "$INSTALL_IP_ADDR" "$INSTALL_IP_IFACE" <<<"$ENSURE_IP_SNIPPET" || true
    # ---- NEW: start a watchdog that re-adds the IP if removed ----
    start_ip_monitor "$ip" "$INSTALL_IP_ADDR" "$INSTALL_IP_IFACE"
  else
    echo "[IP] Skipping ensure; INSTALL_IP_ADDR is empty"
  fi

  if [[ -z "$pth" || "$pth" == "$ip" ]]; then
    echo "❌ No OLD_BUILD_PATH specified for $ip in $SERVER_FILE (UI param ignored by design). Skipping."
    any_failed=1
    continue
  fi

  server_path="$(normalize_k8s_path "$pth" "$OLD_VERSION")"
  echo "📁 Using (normalized): $server_path"

  # 1) Pre-check: Kubernetes present?
  if remote_cluster_present "$ip"; then
    echo "✅ Kubernetes detected on $ip — proceeding."
  else
    echo "ℹ️  No Kubernetes detected on $ip — skipping this server."
    continue
  fi

  req="$server_path/$KSPRAY_DIR/requirements.txt"

  # 2) Ensure requirements.txt; if missing, start installer briefly to generate it
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

  # ---- NEW: stop the per-host IP monitor now that this host's reset flow is done ----
  for _it in "${IP_MON_IDS[@]}"; do
    [[ "${_it%%|*}" == "$ip" ]] || continue
    stop_ip_monitor "$ip" "${_it#*|}" || true
  done

done < <(read_server_entries)

echo ""
if [[ $any_failed -ne 0 ]]; then
  echo "❌ One or more servers failed."
  exit 1
fi
echo "🎉 Completed all servers successfully."
