#!/usr/bin/env bash
# scripts/cluster_reset.sh
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi

set -euo pipefail

# ===== Inputs =====
CR="${CLUSTER_RESET:-Yes}"                         # run gate (Yes/True/1)
SSH_KEY="${SSH_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"
SERVER_FILE="${SERVER_FILE:-server_pci_map.txt}"   # <name>:<ip>:<path>:...
KSPRAY_DIR="${KSPRAY_DIR:-kubespray-2.27.0}"
K8S_VER="${K8S_VER:-1.31.4}"
OLD_VERSION="${OLD_VERSION:-}"                     # e.g., 6.3.0_EA3

RESET_YML_WS="${RESET_YML_WS:-$WORKSPACE/reset.yml}"
REQ_WAIT_SECS="${REQ_WAIT_SECS:-360}"
RETRY_COUNT="${RETRY_COUNT:-3}"
RETRY_DELAY_SECS="${RETRY_DELAY_SECS:-10}"
INSTALL_NAME="${INSTALL_NAME:-install_k8s.sh}"
UNINSTALL_NAME="${UNINSTALL_NAME:-uninstall_k8s.sh}"

# Alias IP watch parameters
: "${INSTALL_IP_ADDR:=}"                           # e.g. 10.10.10.20/24
CIDR="${CIDR:-${INSTALL_IP_ADDR:-}}"
IP_MONITOR_INTERVAL="${IP_MONITOR_INTERVAL:-30}"

# ===== Gate & validation =====
shopt -s nocasematch
if [[ ! "$CR" =~ ^(yes|true|1)$ ]]; then
  echo "ℹ️  CLUSTER_RESET gate disabled (got '$CR'). Skipping."
  exit 0
fi
shopt -u nocasematch

[[ -f "$SSH_KEY" ]]     || { echo "❌ SSH key not found: $SSH_KEY"; exit 1; }
chmod 600 "$SSH_KEY" || true
[[ -f "$SERVER_FILE" ]] || { echo "❌ $SERVER_FILE not found"; exit 1; }

# ===== Utils =====
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15"

ts(){ date '+%Y-%m-%d %H:%M:%S'; }
log(){ printf '[%s] %s\n' "$(ts)" "$*"; }
rsh(){ ssh $SSH_OPTS -i "$SSH_KEY" "root@$1" "${@:2}"; }
rscp(){ scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY" "$2" "root@$1:$3"; }
trim(){ awk '{$1=$1;print}' <<<"$*"; }

# Parse server file into: name ip base mode n3 n6 n4 amf
parse_line(){
  local line="$1"
  if [[ "$line" == \#* || -z "$line" ]]; then return 1; fi
  IFS=':' read -r f1 f2 f3 f4 f5 f6 f7 f8 <<<"$line"
  if [[ "$f1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'NA %s %s VM NA NA NA NA\n' "$f1" "$f2"
  else
    printf '%s %s %s %s %s %s %s %s\n' "$f1" "$f2" "$f3" "${f4:-VM}" "${f5:-NA}" "${f6:-NA}" "${f7:-NA}" "${f8:-NA}"
  fi
}

remote_has_k8s(){
  local ip="$1"
  rsh "$ip" bash -lc '
    set -e
    command -v kubectl >/dev/null 2>&1 || command -v crictl >/dev/null 2>&1 || command -v kubeadm >/dev/null 2>&1
  '
}

remote_find_old_sp(){
  local ip="$1" base="$2"
  if [[ "$base" =~ /k8s-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$base"; return
  fi
  if [[ "$base" =~ /TRILLIUM_5GCN_CNF_REL_ ]]; then
    if rsh "$ip" test -d "$base/common/tools/install/k8s-v${K8S_VER}"; then
      echo "$base/common/tools/install/k8s-v${K8S_VER}"; return
    fi
    echo "$base"; return
  fi
  if [[ "$base" =~ /TRILLIUM_5GCN_CNF_REL_[0-9]+\.[0-9]+\.[0-9]+[^/]*/common/tools/install$ ]]; then
    echo "$base/k8s-v${K8S_VER}"; return
  fi
  if [[ "$base" =~ /([0-9]+\.[0-9]+\.[0-9]+)(/(EA[0-9]+))?$ ]]; then
    local num tag rel_with rel_without probe
    num="$(printf '%s\n' "$base" | sed -n 's#.*/\([0-9]\+\.[0-9]\+\.[0-9]\+\)\(/\(EA[0-9]\+\)\)\?$#\1#p')"
    tag="$(printf '%s\n' "$base" | sed -n 's#.*/[0-9]\+\.[0-9]\+\.[0-9]\+\(/\(EA[0-9]\+\)\)\?$#\2#p' | sed 's#^/##')"
    rel_with="TRILLIUM_5GCN_CNF_REL_${num}${tag:+_${tag}}"
    rel_without="TRILLIUM_5GCN_CNF_REL_${num}"
    for rel in "$rel_with" "$rel_without"; do
      probe="$base/$rel/common/tools/install/k8s-v${K8S_VER}"
      if rsh "$ip" test -d "$probe"; then echo "$probe"; return; fi
    done
  fi
  echo "$base"
}

ensure_requirements_or_k8s(){
  local ip="$1" sp="$2"
  if remote_has_k8s "$ip"; then
    log "✅ Kubernetes detected on $ip — proceeding."
    return 0
  fi
  log "ℹ️ Kubernetes not detected — ensuring $sp/requirements.txt via $INSTALL_NAME"
  rsh "$ip" bash -lc '
    set -euo pipefail
    cd "'"$sp"'"
    if [ -x "./'"$INSTALL_NAME"'" ]; then
      sed -i "s/\r$//" "./'"$INSTALL_NAME"'" 2>/dev/null || true
      chmod +x "./'"$INSTALL_NAME"'" || true
      nohup bash -lc "./'"$INSTALL_NAME"'" >/tmp/_install.out 2>&1 &
      echo $! >/tmp/_install.pid
    fi
  '
  local waited=0
  while (( waited < REQ_WAIT_SECS )); do
    if rsh "$ip" test -f "$sp/requirements.txt"; then
      log "✅ requirements.txt present"
      break
    fi
    sleep 5; (( waited+=5 ))
  done
  rsh "$ip" bash -lc '
    set -e
    if [ -s /tmp/_install.pid ] && ps -p "$(cat /tmp/_install.pid 2>/dev/null)" >/dev/null 2>&1; then
      kill "$(cat /tmp/_install.pid)" 2>/dev/null || true
      sleep 2
      ps -p "$(cat /tmp/_install.pid)" >/dev/null 2>&1 && kill -9 "$(cat /tmp/_install.pid)" 2>/dev/null || true
    fi
    rm -f /tmp/_install.pid /tmp/_install.out 2>/dev/null || true
  '
}

swap_reset_and_inventory(){
  local ip="$1" sp="$2"
  local kdir="$sp/$KSPRAY_DIR"
  rsh "$ip" bash -lc '
    set -euo pipefail
    cd "'"$kdir"'" || exit 0
    mkdir -p /tmp >/dev/null 2>&1 || true
    if [ -f playbooks/reset.yml ]; then
      cp -f playbooks/reset.yml "/tmp/reset_backup_$(date +%s)_$$.yml"
      echo "[SWAP] reset.yml -> '"$kdir"'/playbooks/reset.yml (backup $(ls -1t /tmp/reset_backup_*_*.yml | head -n1))"
    fi
    if [ -f inventory/sample/hosts.yaml ]; then
      cp -f inventory/sample/hosts.yaml "/tmp/inventory_backup_$(date +%s)_$$.yml"
      echo "[SWAP] inventory: '"$kdir"'/inventory/sample/hosts.yaml ← '"$sp"'/k8s-yamls/hosts.yaml (backup $(ls -1t /tmp/inventory_backup_*_*.yml | head -n1))"
    fi
  '
  [[ -f "$RESET_YML_WS" ]] && rscp "$ip" "$RESET_YML_WS" "$kdir/playbooks/reset.yml"
  rsh "$ip" bash -lc '
    set -e
    if [ -f "'"$sp"'/k8s-yamls/hosts.yaml" ]; then
      cp -f "'"$sp"'/k8s-yamls/hosts.yaml" "'"$kdir"'/inventory/sample/hosts.yaml"
    fi
  '
}

restore_reset_override(){
  local ip="$1" sp="$2"
  rsh "$ip" bash -lc '
    set -e
    last="$(ls -1t /tmp/reset_backup_*_*.yml 2>/dev/null | head -n1 || true)"
    if [ -n "$last" ]; then
      cp -f "$last" "'"$sp"'/'"$KSPRAY_DIR"'/playbooks/reset.yml"
      echo "[RESTORE] reset: restored '"$sp"'/'"$KSPRAY_DIR"'/playbooks/reset.yml"
    else
      echo "[RESTORE] reset: no ctx"
    fi
  '
}
restore_inventory_override(){
  local ip="$1" sp="$2"
  rsh "$ip" bash -lc '
    set -e
    last="$(ls -1t /tmp/inventory_backup_*_*.yml 2>/dev/null | head -n1 || true)"
    if [ -n "$last" ]; then
      cp -f "$last" "'"$sp"'/'"$KSPRAY_DIR"'/inventory/sample/hosts.yaml"
      echo "[RESTORE] inventory: restored '"$sp"'/'"$KSPRAY_DIR"'/inventory/sample/hosts.yaml"
    else
      echo "[RESTORE] inventory: no ctx"
    fi
  '
}

run_uninstall_with_retries(){
  local ip="$1" sp="$2"
  local attempt=1
  while (( attempt <= RETRY_COUNT )); do
    echo "🧹 Running $UNINSTALL_NAME on $ip (attempt $attempt/$RETRY_COUNT)..."
    if ssh $SSH_OPTS -i "$SSH_KEY" "root@$ip" bash -euo pipefail -s -- "$sp" "$UNINSTALL_NAME" "${CIDR:-}" "${IP_MONITOR_INTERVAL:-30}" <<'EOF'
set -euo pipefail
SP="$1"; NAME="$2"; CIDR="${3:-}"; WATCH="${4:-30}"
cd "$SP"

# normalize uninstall script
sed -i 's/\r$//' "$NAME" 2>/dev/null || true
chmod +x "$NAME" || true
head -n1 "$NAME" | grep -q bash || sed -i '1s|^#!.*|#!/usr/bin/env bash|' "$NAME"

# Put your ip_alias_check.sh onto the node (verbatim), then launch it
if [ -n "${CIDR:-}" ]; then
  cat >/tmp/ip_alias_check.sh <<'MON'
#!/usr/bin/env sh
# Keep <CIDR> present; auto-pick iface (default-route first, then physical NICs)
# Usage:
#   sudo ./ip_alias_auto_watch.sh 10.10.10.20/24
#   sudo ./ip_alias_auto_watch.sh -w 15 -l /var/log/alias_ipmon.log 10.10.10.20/24
set -eu
export PATH="/sbin:/usr/sbin:/bin:/usr/bin:$PATH"

# ---- args ----
WATCH=30
LOG="/var/log/alias_ipmon.log"
CIDR="${1:-${INSTALL_IP_ADDR:-}}"
while [ $# -gt 0 ]; do
  case "$1" in
    -w|--watch) WATCH="${2:-30}"; shift 2 ;;
    -l|--log) LOG="${2:-/var/log/alias_ipmon.log}"; shift 2 ;;
    -h|--help) echo "Usage: $0 [-w SECS] [-l LOGFILE] <CIDR>"; exit 0 ;;
    *) CIDR="$1"; shift ;;
  esac
done
: "${CIDR:?usage: $0 [-w SECS] [-l LOGFILE] <CIDR>  e.g. 10.10.10.20/24}"

# ---- validate CIDR (no regex) ----
case "$CIDR" in */*) : ;; *) echo "[ipmon] ❌ invalid CIDR (missing /): '$CIDR'"; exit 2 ;; esac
IP_ONLY="${CIDR%/*}"
MASK="${CIDR#*/}"
case "$MASK" in ''|*[!0-9]*) echo "[ipmon] ❌ invalid mask: '$MASK'"; exit 2 ;; esac
[ "$MASK" -ge 0 ] && [ "$MASK" -le 32 ] || { echo "[ipmon] ❌ mask OOR: $MASK"; exit 2; }
# octets
set -- $(printf "%s" "$IP_ONLY" | awk -F. 'NF==4{print $1,$2,$3,$4}')
[ $# -eq 4 ] || { echo "[ipmon] ❌ invalid IPv4: '$IP_ONLY'"; exit 2; }
for o in "$1" "$2" "$3" "$4"; do
  case "$o" in ''|*[!0-9]*) echo "[ipmon] ❌ bad octet: '$o'"; exit 2 ;; esac
  [ "$o" -ge 0 ] && [ "$o" -le 255 ] || { echo "[ipmon] ❌ octet OOR: '$o'"; exit 2; }
done

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[ipmon] ❌ missing '$1'"; exit 2; }; }
need ip
ts(){ date '+%F %T' 2>/dev/null || echo ""; }
log(){ printf "[%s] [ipmon] %s\n" "$(ts)" "$*" | tee -a "$LOG" >/dev/null; }

present_any(){ ip -4 addr show | awk '/inet /{print $2}' | cut -d/ -f1 | grep -qx "$IP_ONLY"; }
present_if(){ ip -4 addr show dev "$1" | awk '/inet /{print $2}' | cut -d/ -f1 | grep -qx "$IP_ONLY"; }

cands(){
  DEFIF="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"
  PHYS="$(ip -o link 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' \
    | grep -E '^(en|eth|ens|eno|em|bond|br)' \
    | grep -Ev '(^lo$|docker|podman|cni|flannel|cilium|calico|weave|veth|tun|tap|virbr|wg)')"
  C=""; [ -n "${DEFIF:-}" ] && C="$DEFIF"
  for n in $PHYS; do [ "$n" = "$DEFIF" ] && continue; C="$C $n"; done
  echo "$C"
}

ensure_once(){
  C="$(cands)"; [ -n "$(printf %s "$C" | tr -d ' ')" ] || { log "no iface candidates"; return 1; }
  for IF in $C; do
    ip link show "$IF" >/dev/null 2>&1 || continue
    ip link set dev "$IF" up >/dev/null 2>&1 || true
    log "…trying $CIDR on $IF"
    if ip addr replace "$CIDR" dev "$IF" 2>/tmp/ip_alias_err.log; then
      sleep 1
      if present_if "$IF"; then log "✅ $CIDR present on $IF"; return 0; fi
    fi
  done
  ERR="$(tr -d '\n' </tmp/ip_alias_err.log 2>/dev/null || true)"
  log "❌ add failed: ${ERR:-unknown}"
  return 1
}

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: >>"$LOG" 2>/dev/null || true
log "watch start for $CIDR (interval=${WATCH}s)"

if present_any; then
  log "Already present: $IP_ONLY"
else
  ensure_once || true
fi

MON_PID=""
( ip monitor address 2>/dev/null | while read -r _; do
    if ! present_any; then log "addr change; restoring $CIDR"; ensure_once || true; fi
  done ) &
MON_PID=$!
log "event monitor pid=$MON_PID"
trap ' [ -n "$MON_PID" ] && kill "$MON_PID" 2>/dev/null || true; log "stopped"; exit 0 ' INT TERM EXIT

case "$WATCH" in ''|*[!0-9]*) WATCH=30 ;; esac
while :; do
  if ! present_any; then
    log "periodic restore; re-adding $CIDR"
    ensure_once || true
  fi
  log "heartbeat (present=$(present_any && echo yes || echo no))"
  sleep "$WATCH"
done
MON
  chmod +x /tmp/ip_alias_check.sh || true
  nohup /tmp/ip_alias_check.sh -w "$WATCH" -l /var/log/alias_ipmon.log "$CIDR" >/dev/null 2>&1 &
  echo $! >/tmp/_ipmon.pid
  trap ' PID=$(cat /tmp/_ipmon.pid 2>/dev/null || true); [ -n "$PID" ] && kill "$PID" 2>/dev/null || true ' EXIT
fi

echo "[uninstall] starting"
bash -xeuo pipefail "$NAME"
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

echo "Jenkins reset.yml: ${RESET_YML_WS:-<none>}"
while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="$(trim "$raw")"; [[ -z "$line" || "$line" == \#* ]] && continue
  read -r name ip base mode n3 n6 n4 amf <<<"$(parse_line "$line")"

  echo; echo "🔧 Server: $ip"

  # Ensure alias IP once (best-effort) before uninstall begins
  if [[ -n "${INSTALL_IP_ADDR:-}" ]]; then
    echo "[IP] Ensuring ${INSTALL_IP_ADDR}"
    rsh "$ip" bash -lc '
      set -euo pipefail
      CIDR="'"${INSTALL_IP_ADDR}"'"; IP="${CIDR%%/*}"
      if ip -4 addr show | awk "/inet /{print \$2}" | cut -d/ -f1 | grep -qx "$IP"; then
        echo "[IP] Already present: $IP"
      else
        DEFIF=$(ip route | awk "/^default/{print \$5; exit}" || true)
        IF=${DEFIF:-$(ip -o link | awk -F": " "{print \$2}" | sed "s/@.*//" | grep -E "^(en|eth|ens|eno|em|bond|br)" | grep -Ev "(^lo$|docker|podman|cni|flannel|cilium|calico|weave|veth|tun|tap|virbr|wg)" | head -n1)}
        [ -n "$IF" ] || { echo "[IP] ❌ no suitable iface"; exit 1; }
        ip addr replace "$CIDR" dev "$IF"
        echo "[IP] Added $CIDR on $IF"
      fi
    '
  fi

  # Locate old build path on remote
  sp="$(remote_find_old_sp "$ip" "$base")"
  echo "📁 Using (normalized): $sp"

  # Ensure requirements/k8s presence (non-fatal if timeout)
  ensure_requirements_or_k8s "$ip" "$sp" || true

  # Swap reset.yml + inventory
  swap_reset_and_inventory "$ip" "$sp"

  # Uninstall with retries (with your ip_alias_check.sh watchdog running remotely)
  if ! run_uninstall_with_retries "$ip" "$sp"; then
    echo "❌ Uninstall failed after ${RETRY_COUNT} attempts on $ip"
  fi

  # Restore backups
  restore_reset_override "$ip" "$sp" || true
  restore_inventory_override "$ip" "$sp" || true
done < "$SERVER_FILE"

echo; echo "✅ Cluster reset step finished."
