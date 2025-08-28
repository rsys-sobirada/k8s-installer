#!/usr/bin/env sh
# Keep <CIDR> present; auto-pick iface (default-route first, then physical NICs)
# Usage:
#   sudo ./ip_alias_check.sh 10.10.10.20/24
#   sudo ./ip_alias_check.sh -w 15 -l /var/log/alias_ipmon.log 10.10.10.20/24
#   sudo IFACE=enp1s0 ./ip_alias_check.sh 10.10.10.20/24
set -eu
export PATH="/usr/local/sbin:/sbin:/usr/sbin:/bin:/usr/bin:$PATH"

# ---- args ----
WATCH=30
LOG="/var/log/alias_ipmon.log"
CIDR=""
IFACE="${IFACE:-}"   # may be set via env; CLI flag wins

while [ $# -gt 0 ]; do
  case "$1" in
    -w|--watch) WATCH="${2:-30}"; shift 2 ;;
    -l|--log)   LOG="${2:-/var/log/alias_ipmon.log}"; shift 2 ;;
    --iface)    IFACE="${2:-}"; shift 2 ;;
    -h|--help)  echo "Usage: $0 [-w SECS] [-l LOGFILE] [--iface IFACE] <CIDR>"; exit 0 ;;
    --) shift; break ;;
    -*) echo "[ipmon] ❌ unknown option: $1"; exit 2 ;;
    *)  CIDR="$1"; shift ;;
  esac
done

# default CIDR from env if not provided positionally
[ -n "${CIDR:-}" ] || CIDR="${INSTALL_IP_ADDR:-}"
: "${CIDR:?usage: $0 [-w SECS] [-l LOGFILE] [--iface IFACE] <CIDR>  e.g. 10.10.10.20/24}"

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
  # use pinned IFACE if provided
  if [ -n "${IFACE:-}" ]; then
    ip link show "$IFACE" >/dev/null 2>&1 || { log "iface '$IFACE' not found"; return 1; }
    ip link set dev "$IFACE" up >/dev/null 2>&1 || true
    ERRF="$(mktemp -p /tmp ip_alias_err.XXXXXX 2>/dev/null || echo /tmp/ip_alias_err.$$)"
    if ip addr replace "$CIDR" dev "$IFACE" 2>"$ERRF"; then
      sleep 1; present_if "$IFACE" && { log "✅ $CIDR present on $IFACE"; rm -f "$ERRF"; return 0; }
    fi
    ERR="$(tr -d '\n' <"$ERRF" 2>/dev/null || true)"; rm -f "$ERRF"
    log "❌ add failed on $IFACE: ${ERR:-unknown}"; return 1
  fi

  C="$(cands)"; [ -n "$(printf %s "$C" | tr -d ' ')" ] || { log "no iface candidates"; return 1; }
  for IF in $C; do
    ip link show "$IF" >/dev/null 2>&1 || continue
    ip link set dev "$IF" up >/dev/null 2>&1 || true
    log "…trying $CIDR on $IF"
    ERRF="$(mktemp -p /tmp ip_alias_err.XXXXXX 2>/dev/null || echo /tmp/ip_alias_err.$$)"
    if ip addr replace "$CIDR" dev "$IF" 2>"$ERRF"; then
      sleep 1; present_if "$IF" && { log "✅ $CIDR present on $IF"; rm -f "$ERRF"; return 0; }
    fi
    ERR="$(tr -d '\n' <"$ERRF" 2>/dev/null || true)"; rm -f "$ERRF"
  done
  log "❌ add failed: ${ERR:-unknown}"
  return 1
}

# ---- init ----
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: >>"$LOG" 2>/dev/null || true
log "watch start for $CIDR (interval=${WATCH}s${IFACE:+, iface=$IFACE})"

if present_any; then
  log "Already present: $IP_ONLY"
else
  ensure_once || true
fi

# event-driven + periodic monitoring (both)
MON_PID=""
( ip monitor address 2>/dev/null | while read -r _; do
    if ! present_any; then log "addr change; restoring $CIDR"; ensure_once || true; fi
  done ) &
MON_PID=$!
log "event monitor pid=$MON_PID"
trap ' [ -n "$MON_PID" ] && kill "$MON_PID" 2>/dev/null || true; log "stopped"; exit 0 ' INT TERM EXIT

# periodic heartbeat + self-heal
case "$WATCH" in ''|*[!0-9]*) WATCH=30 ;; esac
while :; do
  if ! present_any; then
    log "periodic restore; re-adding $CIDR"
    ensure_once || true
  fi
  log "heartbeat (present=$(present_any && echo yes || echo no))"
  sleep "$WATCH"
done
