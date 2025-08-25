#!/usr/bin/env sh
set -eu
export PATH="/sbin:/usr/sbin:/bin:/usr/bin:$PATH"

# Accept CIDR from $1 or INSTALL_IP_ADDR env
IP_CIDR="${1:-${INSTALL_IP_ADDR:-}}"
: "${IP_CIDR:?empty IP_CIDR; pass as arg or set INSTALL_IP_ADDR}"

# --- CIDR validation without regex ---
case "$IP_CIDR" in */*) : ;; *) echo "[alias-ip] ❌ invalid CIDR (missing /): '$IP_CIDR'"; exit 2 ;; esac
IP_ONLY="${IP_CIDR%/*}"
MASK="${IP_CIDR#*/}"
case "$MASK" in ''|*[!0-9]*) echo "[alias-ip] ❌ invalid mask: '$MASK'"; exit 2 ;; esac
[ "$MASK" -ge 0 ] && [ "$MASK" -le 32 ] || { echo "[alias-ip] ❌ mask out of range: '$MASK'"; exit 2; }

# Split and validate IPv4 octets
set -- $(printf "%s" "$IP_ONLY" | awk -F. 'NF==4{print $1,$2,$3,$4}')
[ "$#" -eq 4 ] || { echo "[alias-ip] ❌ invalid IPv4: '$IP_ONLY'"; exit 2; }
for o in "$1" "$2" "$3" "$4"; do
  case "$o" in ''|*[!0-9]*) echo "[alias-ip] ❌ invalid octet: '$o'"; exit 2 ;; esac
  [ "$o" -ge 0 ] && [ "$o" -le 255 ] || { echo "[alias-ip] ❌ octet out of range: '$o'"; exit 2; }
done

# Already present anywhere?
if ip -4 addr show | awk '/inet /{print $2}' | cut -d/ -f1 | grep -qx "$IP_ONLY"; then
  echo "[alias-ip] ✅ Already present: $IP_ONLY"
  exit 0
fi

# Candidate ifaces: default-route first, then physical-looking NICs (exclude virtual/container)
CANDIDATES=""
DEFIF="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"
[ -n "${DEFIF:-}" ] && CANDIDATES="$DEFIF"
PHYS_NICS="$(ip -o link 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//'       | grep -E '^(en|eth|ens|eno|em|bond|br)'       | grep -Ev '(^lo$|docker|podman|cni|flannel|cilium|calico|weave|veth|tun|tap|virbr|wg)')"
for nic in $PHYS_NICS; do [ -n "${DEFIF:-}" ] && [ "$nic" = "$DEFIF" ] && continue; CANDIDATES="$CANDIDATES $nic"; done
[ -n "$(printf %s "$CANDIDATES" | tr -d ' ')" ] || { echo "[alias-ip] ❌ no suitable interface found"; exit 2; }

# Try candidates
ok=1
for IFACE in $CANDIDATES; do
  ip link show "$IFACE" >/dev/null 2>&1 || continue
  ip link set dev "$IFACE" up >/dev/null 2>&1 || true
  echo "[alias-ip] …trying $IP_CIDR on $IFACE"
  if ip addr replace "$IP_CIDR" dev "$IFACE" 2>/tmp/ip_alias_err.log; then
    sleep 1
    if ip -4 addr show dev "$IFACE" | awk '/inet /{print $2}' | cut -d/ -f1 | grep -qx "$IP_ONLY"; then
      echo "[alias-ip] ✅ $IP_CIDR present on $IFACE"
      ok=0
      break
    fi
  fi
done

if [ $ok -ne 0 ]; then
  ERR="$(tr -d '\n' </tmp/ip_alias_err.log 2>/dev/null || true)"
  echo "[alias-ip] ❌ Failed to add $IP_CIDR. Kernel says: ${ERR:-unknown error}"
  exit 2
fi
exit 0
