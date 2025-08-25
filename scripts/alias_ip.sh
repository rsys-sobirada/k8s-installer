# --- replace the grep -Eq line with this block ---
# Validate CIDR without regex
case "$IP_CIDR" in */*) : ;; *) echo "[alias-ip] ❌ invalid CIDR (missing /): '$IP_CIDR'"; exit 2 ;; esac
IP_ONLY="${IP_CIDR%/*}"
MASK="${IP_CIDR#*/}"
case "$MASK" in ''|*[!0-9]*) echo "[alias-ip] ❌ invalid mask: '$MASK'"; exit 2 ;; esac
[ "$MASK" -ge 0 ] && [ "$MASK" -le 32 ] || { echo "[alias-ip] ❌ mask out of range: '$MASK'"; exit 2; }
set -- $(printf "%s" "$IP_ONLY" | awk -F. 'NF==4{print $1,$2,$3,$4}')
[ $# -eq 4 ] || { echo "[alias-ip] ❌ invalid IPv4: '$IP_ONLY'"; exit 2; }
for o in "$1" "$2" "$3" "$4"; do
  case "$o" in ''|*[!0-9]*) echo "[alias-ip] ❌ invalid octet: '$o'"; exit 2 ;; esac
  [ "$o" -ge 0 ] && [ "$o" -le 255 ] || { echo "[alias-ip] ❌ octet out of range: '$o'"; exit 2; }
done
# --- end replacement ---
