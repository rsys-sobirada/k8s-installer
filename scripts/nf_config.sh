#!/usr/bin/env bash
# nf_config.sh — configure NF charts on one or more CNs based on server_pci_map.txt
# Expected line format (no spaces):
#   <name>:<ip>:<build_path>:<VM|SRIOV>:<N3_PCI|N3_IFACE>:<N6_PCI|N6_IFACE>:<N4_BASE_CIDR>:<AMF_N2_IP>
#
# Example:
#   server1:172.27.28.193:/home/labadmin/6.3.0/EA3:VM:0000:08:00.0:0000:09:00.0:10.11.10.0/30:12.12.1.100
#
# Requires env from Jenkins:
#   SERVER_FILE (server_pci_map.txt), SSH_KEY, NEW_BUILD_PATH, NEW_VERSION, DEPLOYMENT_TYPE
# Optional:
#   HOST_USER=root (default), INSTALL_IP_ADDR (for preflight job), CN_BOOTSTRAP_PASS (only if you push keys by password)

set -euo pipefail

log(){ printf '%s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- env sanity -----------------------------------------------------------------
: "${SERVER_FILE:?SERVER_FILE missing}"
: "${SSH_KEY:?SSH_KEY missing}"
: "${NEW_BUILD_PATH:?NEW_BUILD_PATH missing}"
: "${NEW_VERSION:?NEW_VERSION missing}"
: "${DEPLOYMENT_TYPE:?DEPLOYMENT_TYPE missing}"
HOST_USER="${HOST_USER:-root}"

# Extract semantic version like 6.3.0 from 6.3.0_EA3, 6.3.0, etc.
VER="$(printf '%s\n' "$NEW_VERSION" | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p')"
[ -n "$VER" ] || die "Could not derive VER from NEW_VERSION='$NEW_VERSION'"

# capacity from DEPLOYMENT_TYPE
case "${DEPLOYMENT_TYPE,,}" in
  low)    CAP="LOW" ;;
  medium) CAP="MEDIUM" ;;
  high)   CAP="HIGH" ;;
  *)      CAP="LOW" ;; # safe default
esac

log "[nf_config] NEW_BUILD_PATH=$NEW_BUILD_PATH"
log "[nf_config] NEW_VERSION=$NEW_VERSION (VER=$VER)"
log "[nf_config] DEPLOYMENT_TYPE=$DEPLOYMENT_TYPE (CAP=$CAP)"
log "[nf_config] SERVER_FILE=$SERVER_FILE"

# --- helpers --------------------------------------------------------------------

is_pci() { [[ "$1" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]+$ ]]; }

# Resolve interface name on remote host to PCI (0000:bb:ss.f)
resolve_iface_to_pci() { # $1 host $2 iface
  local host="$1" iface="$2"
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "${HOST_USER}@${host}" \
    "readlink -f /sys/class/net/'$iface'/device 2>/dev/null | sed -nE 's@.*/([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\\.[0-9a-f])\$@\\1@p'" \
    || true
}

# Parse one server line robustly (no spaces). Prints 8 tab-separated fields:
# name ip build mode n3_token n6_token n4_cidr amf_ip
parse_line() { # $1 raw line
  awk -v line="$1" -F: '
    BEGIN{
      # first 4 fixed fields
      n=split(line,a,":");
      if(n<7){ print ""; exit 0 } # invalid
      name=a[1]; ip=a[2]; bpath=a[3]; mode=a[4];
      # last 2 are N4 and AMF (AMF may be missing)
      amf=a[n]; n4=a[n-1];
      # rebuild the middle (N3+N6) from a[5..n-2]
      mid=""; for(i=5;i<=n-2;i++){ mid=mid (mid==""?"":":") a[i] }
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", name,ip,bpath,mode,mid, "", n4, amf;
    }'
}

# Split N3+N6 token into two components (each either PCI or iface)
split_n3n6() { # $1 combined, set globals N3_TKN N6_TKN
  local c="$1"
  N3_TKN=""; N6_TKN=""
  # Both are PCI -> 6 colon components total when splitting
  IFS=: read -r a b c1 d e f <<<"$c" || true
  if [ -n "${f:-}" ]; then
    # could be PCI:PCI (six parts) -> reconstruct
    N3_TKN="${a}:${b}:${c1}"
    N6_TKN="${d}:${e}:${f}"
    if is_pci "$N3_TKN" && is_pci "$N6_TKN"; then return 0; fi
  fi
  # iface:iface
  if [[ "$c" =~ ^[^:]+:[^:]+$ ]]; then
    N3_TKN="${c%%:*}"
    N6_TKN="${c##*:}"
    return 0
  fi
  # mixed: <iface>:<pci> or <pci>:<iface>
  if [[ "$c" =~ :[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]+$ ]]; then
    N6_TKN="${c##*:}"
    N3_TKN="${c%:*}"
    return 0
  fi
  if [[ "$c" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]+: ]]; then
    N3_TKN="${c%%:*:*:*}"
    N6_TKN="${c#*:}" ; N6_TKN="${N6_TKN#*:}" ; N6_TKN="${N6_TKN#*:}" # whatever remains (iface)
    return 0
  fi
  # fallback: assume single colon separates them
  N3_TKN="${c%%:*}"
  N6_TKN="${c##*:}"
}

# Build exclude IPs from a base CIDR like 10.11.10.0/30
compute_excludes() { # $1 CIDR -> EXCL_UPF / EXCL_SMF
  local cidr="$1"
  local b3 last
  b3="$(printf '%s\n' "$cidr" | awk -F'[./]' '{print $1"."$2"."$3}')"
  last="$(printf '%s\n' "$cidr" | awk -F'[./]' '{print $4}')"
  EXCL_UPF="${b3}.$((last+1))/32"
  EXCL_SMF="${b3}.$((last+2))/32"
}

# --- per-host runner ------------------------------------------------------------
run_for_host() { # $1 name $2 host_ip $3 bpath $4 mode $5 n3t $6 n6t $7 n4cidr $8 amf
  local NAME="$1" HOST="$2" BPATH="$3" MODE="$4" N3TOK="$5" N6TOK="$6" N4CIDR="$7" AMFIP="${8:-}"

  # Resolve interface tokens to PCI on the remote host
  local N3PCI="$N3TOK" N6PCI="$N6TOK"
  if ! is_pci "$N3PCI"; then
    N3PCI="$(resolve_iface_to_pci "$HOST" "$N3TOK")"
    [ -n "$N3PCI" ] || die "Could not resolve N3 iface '$N3TOK' on $HOST"
  fi
  if ! is_pci "$N6PCI"; then
    N6PCI="$(resolve_iface_to_pci "$HOST" "$N6TOK")"
    [ -n "$N6PCI" ] || die "Could not resolve N6 iface '$N6TOK' on $HOST"
  fi

  compute_excludes "$N4CIDR"
  local NF_ROOT="${NEW_BUILD_PATH}/TRILLIUM_5GCN_CNF_REL_${VER}/nf-services/scripts"
  log "[nf_config][$HOST] ▶ start"
  log "[nf_config][$HOST] parsed: MODE='$MODE' N3='$N3PCI' N6='$N6PCI' N4='$N4CIDR' AMF='${AMFIP:-}'"

  # Send a small script to the CN to do all YAML edits atomically.
  ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "${HOST_USER}@${HOST}" \
    env NF_ROOT="$NF_ROOT" VER="$VER" CAP="$CAP" HOST_IP="$HOST" MODE="$MODE" \
        N3PCI="$N3PCI" N6PCI="$N6PCI" N4RANGE="$N4CIDR" EXCL_UPF="$EXCL_UPF" EXCL_SMF="$EXCL_SMF" AMFIP="$AMFIP" \
    bash -s <<'REMOTE'
set -eu

[ -d "$NF_ROOT" ] || { echo "[remote] NF_ROOT not found: $NF_ROOT"; exit 2; }
echo "[remote] NF_ROOT=$NF_ROOT"

# 1) global-values.yaml tweaks
GV="$NF_ROOT/global-values.yaml"

# capacitySetup
sed -i -E 's/(capacitySetup:[[:space:]]*")[^"]*(")/\1'"$CAP"'\2/' "$GV"

# k8sCpuMgrStaticPolicyEnable: false if LOW else true
if [ "$CAP" = "LOW" ]; then
  sed -i -E 's/(k8sCpuMgrStaticPolicyEnable:[[:space:]]*).*/\1false/' "$GV"
else
  sed -i -E 's/(k8sCpuMgrStaticPolicyEnable:[[:space:]]*).*/\1true/' "$GV"
fi

# ingressExtFQDN: replace only the IP part like 1.1.1.1.nip.io
sed -i -E 's/(ingressExtFQDN:[[:space:]]*)[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\.nip\.io)/\1'"$HOST_IP"'\2/' "$GV"

echo "[remote] global-values.yaml updated."

# 2) Version bump (v1 -> VER) on all *_values.yaml (match :v1")
find "$NF_ROOT" -maxdepth 1 -type f -name '*-values.yaml' -print0 \
 | xargs -0 -r sed -i -E 's/:v1"/:'"$VER"'"/g'
echo "[remote] replaced :v1\" -> :'"$VER"'\" in files under nf-services/scripts."

# 3) AMF external IP if provided
AMF="$NF_ROOT/amf-1-values.yaml"
if [ -n "${AMFIP:-}" ] && [ -f "$AMF" ]; then
  sed -i -E 's/(externalIP:[[:space:]]*).*/\1'"$AMFIP"'/' "$AMF"
else
  echo "[remote] amf-1-values.yaml: AMF_N2_IP not provided/invalid — skipped"
fi

# 4) UPF link type & PCI addresses
UPF="$NF_ROOT/upf-1-values.yaml"
[ -f "$UPF" ] || { echo "[remote] upf-1-values.yaml missing"; exit 2; }

# intfConfig.type -> "devPassthrough" for VM else "sriov"
UPF_TYPE='devPassthrough'
[ "${MODE,,}" = "sriov" ] && UPF_TYPE='sriov'
awk -v t="$UPF_TYPE" '
  BEGIN{in=0; done=0}
  {
    if ($0 ~ /^[[:space:]]*intfConfig:/) in=1;
    if (in && done==0 && $0 ~ /^[[:space:]]*type:/) {
      sub(/type:.*/, "      type: \"" t "\""); done=1; in=0;
    }
    print
  }' "$UPF" > "$UPF.tmp" && mv "$UPF.tmp" "$UPF"
echo "[remote] upf.type:       type: \"$UPF_TYPE\""

# nguInterface pciAddress -> N3PCI (only the first pciAddress inside nguInterface:)
awk -v pci="$N3PCI" '
  BEGIN{in=0; done=0}
  { line=$0;
    if (line ~ /^[[:space:]]*nguInterface:/) in=1;
    if (in && done==0 && line ~ /^[[:space:]]*pciAddress:/) { sub(/pciAddress:.*/,"        pciAddress: " pci, line); done=1; }
    print line;
    if (in && line ~ /^[[:space:]]*n6Interface_0:/) in=0;
  }' "$UPF" > "$UPF.tmp" && mv "$UPF.tmp" "$UPF"
echo "[remote] upf.ngu pci:         pciAddress: $N3PCI"

# n6Interface_0 pciAddress -> N6PCI (only the first pciAddress inside n6Interface_0:)
awk -v pci="$N6PCI" '
  BEGIN{in=0; done=0}
  { line=$0;
    if (line ~ /^[[:space:]]*n6Interface_0:/) in=1;
    if (in && done==0 && line ~ /^[[:space:]]*pciAddress:/) { sub(/pciAddress:.*/,"        pciAddress: " pci, line); done=1; }
    print line;
    if (in && (line ~ /^[[:space:]]*n6Interface_1:/ || line ~ /^[[:space:]]*n9Interface:/ || line ~ /^[[:space:]]*upfsesscoresteps:/)) in=0;
  }' "$UPF" > "$UPF.tmp" && mv "$UPF.tmp" "$UPF"
echo "[remote] upf.n6  pci:         pciAddress: $N6PCI"

# 5) IPAM: set N4 ranges and excludes in both UPF & SMF
SMF="$NF_ROOT/smf-1-values.yaml"

patch_ipam_range_ipv4() { # $1 file, $2 A.B.C.D/M
  f="$1"; rng="$2"
  awk -v rng="$rng" '
    BEGIN{in_ipam=0; in_ranges=0; done=0}
    {
      l=$0
      if (l ~ /"ipam"[[:space:]]*:[[:space:]]*\{/) in_ipam=1
      if (in_ipam && l ~ /"ipRanges"[[:space:]]*:[[:space:]]*\[/) in_ranges=1
      if (in_ranges && done==0 && l ~ /"range":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/) {
        sub(/"range":[[:space:]]*"[^"]+"/, "\"range\": \"" rng "\"", l); done=1
      }
      print l
      if (in_ranges && l ~ /\]/) in_ranges=0
      if (in_ipam   && l ~ /\}/ && !in_ranges) in_ipam=0
    }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

patch_ipam_exclude_ipv4() { # $1 file, $2 A.B.C.D/32
  f="$1"; exc="$2"
  awk -v exc="$exc" '
    BEGIN{in_ipam=0; in_exc=0; rep=0}
    {
      l=$0
      if (l ~ /"ipam"[[:space:]]*:[[:space:]]*\{/) in_ipam=1
      if (in_ipam && l ~ /"exclude"[[:space:]]*:[[:space:]]*\[/) in_exc=1
      if (in_exc && rep==0 && l ~ /"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/32"/) {
        sub(/"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/32"/, "\"" exc "\"", l); rep=1
      }
      print l
      if (in_exc  && l ~ /\]/) in_exc=0
      if (in_ipam && l ~ /\}/ && !in_exc) in_ipam=0
    }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# apply to UPF
patch_ipam_range_ipv4   "$UPF" "$N4RANGE"
patch_ipam_exclude_ipv4 "$UPF" "$EXCL_UPF"

# apply to SMF (if present)
[ -f "$SMF" ] && {
  patch_ipam_range_ipv4   "$SMF" "$N4RANGE"
  patch_ipam_exclude_ipv4 "$SMF" "$EXCL_SMF"
}

# 6) quick checks
echo "[remote] NF checks:"
grep -n 'externalIP:' "$NF_ROOT/amf-1-values.yaml" || true
awk '/intfConfig:/{f=1} f&&/type:/{print; f=0}' "$UPF" || true
awk '/nguInterface:/, /^[A-Za-z0-9_]+:/{ if(/pciAddress:/) print }' "$UPF" || true
awk '/n6Interface_0:/, /^[A-Za-z0-9_]+:/{ if(/pciAddress:/) print }' "$UPF" || true
grep -nE '"range"|exclude' "$UPF" "$SMF" || true

echo "[remote] ✅ NF config complete on $(hostname -I | awk "{print \$1}")"
REMOTE

  log "[nf_config][$HOST] ◀ done"
}

# --- main loop ------------------------------------------------------------------
while IFS= read -r raw || [ -n "$raw" ]; do
  # skip comments/blank
  [[ -z "$raw" || "$raw" =~ ^[[:space:]]*# ]] && continue

  # Ensure no spaces in the line (as per your latest format)
  line="${raw//[[:space:]]/}"

  # first: name ip build mode … then tail with n3/n6/n4/amf
  parsed="$(parse_line "$line")"
  [ -n "$parsed" ] || { log "[nf_config] skip malformed: $line"; continue; }

  IFS=$'\t' read -r NAME HOST BPATH MODE MID _ N4CIDR AMFIP <<<"$parsed"

  # If the server row provides a build path, prefer NEW_BUILD_PATH (your requirement).
  # But keep BPATH just in case you want to validate later.
  _=:"$BPATH" # no-op to silence shellcheck

  # Split N3+N6 tokens from MID
  split_n3n6 "$MID"
  [ -n "$N3_TKN" ] && [ -n "$N6_TKN" ] || die "Could not split N3/N6 tokens from '$MID'"

  run_for_host "$NAME" "$HOST" "$NEW_BUILD_PATH" "$MODE" "$N3_TKN" "$N6_TKN" "$N4CIDR" "${AMFIP:-}"
done < "$SERVER_FILE"

log "[nf_config] All hosts processed."
