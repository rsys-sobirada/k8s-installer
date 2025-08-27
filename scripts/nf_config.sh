#!/usr/bin/env bash
# scripts/nf_config.sh — Configure NF YAMLs on CNs
# Required env: SERVER_FILE, SSH_KEY, NEW_BUILD_PATH, NEW_VERSION, DEPLOYMENT_TYPE
# Optional env: HOST_USER (default root)
#
# server_pci_map.txt format (no spaces in fields):
# NAME:HOST:/path/to/build:MODE:N3:N6:N4:AMF
# - If N3/N6 are PCI (e.g., 0000:08:00.0), the whole line has 12 colon-separated tokens.
# - If N3/N6 are interface names, the line has 8 tokens.

set -euo pipefail

: "${SERVER_FILE:?missing SERVER_FILE}"
: "${SSH_KEY:?missing SSH_KEY}"
: "${NEW_BUILD_PATH:?missing NEW_BUILD_PATH}"
: "${NEW_VERSION:?missing NEW_VERSION}"
: "${DEPLOYMENT_TYPE:?missing DEPLOYMENT_TYPE}"
HOST_USER="${HOST_USER:-root}"

VER="${NEW_VERSION%%_*}"   # e.g. 6.3.0 from 6.3.0_EA3
case "${DEPLOYMENT_TYPE}" in
  [Ll]ow) CAP="LOW" ;;
  [Hh]igh) CAP="HIGH" ;;
  *) CAP="MEDIUM" ;;
esac

echo "[nf_config] NEW_BUILD_PATH=${NEW_BUILD_PATH}"
echo "[nf_config] NEW_VERSION=${NEW_VERSION} (VER=${VER})"
echo "[nf_config] DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE} (CAP=${CAP})"
echo "[nf_config] SERVER_FILE=${SERVER_FILE}"

# --- iterate lines, skipping blanks/comments ---
while IFS= read -r RAW; do
  [[ -z "$RAW" || "$RAW" =~ ^[[:space:]]*# ]] && continue
  LINE="${RAW//[[:space:]]/}"   # defensively strip whitespace

  # Split by ":" -> array
  IFS=':' read -r -a parts <<< "$LINE"
  n=${#parts[@]}

  NAME=""; HOST=""; OLD_BUILD=""; MODE=""
  N3_VAL=""; N6_VAL=""; N4_CIDR=""; AMF_IP=""

  if (( n == 12 )); then
    # PCI format
    NAME="${parts[0]}"; HOST="${parts[1]}"; OLD_BUILD="${parts[2]}"; MODE="${parts[3]}"
    N3_VAL="${parts[4]}:${parts[5]}:${parts[6]}"
    N6_VAL="${parts[7]}:${parts[8]}:${parts[9]}"
    N4_CIDR="${parts[10]}"; AMF_IP="${parts[11]}"
  elif (( n == 8 )); then
    # iface-name format
    NAME="${parts[0]}"; HOST="${parts[1]}"; OLD_BUILD="${parts[2]}"; MODE="${parts[3]}"
    N3_VAL="${parts[4]}"; N6_VAL="${parts[5]}"; N4_CIDR="${parts[6]}"; AMF_IP="${parts[7]}"
  else
    echo "[nf_config] skip malformed line (expected 8 or 12 fields): ${RAW}"
    continue
  fi

  if [[ -z "$HOST" || -z "$MODE" || -z "$N3_VAL" || -z "$N6_VAL" || -z "$N4_CIDR" || -z "$AMF_IP" ]]; then
    echo "[nf_config] skip: missing required fields in: ${RAW}"
    continue
  fi

  echo "[nf_config][${HOST}] ▶ start"
  echo "[nf_config][${HOST}] parsed: MODE='${MODE}' N3='${N3_VAL}' N6='${N6_VAL}' N4='${N4_CIDR}' AMF='${AMF_IP}'"

  NF_ROOT="${NEW_BUILD_PATH%/}/TRILLIUM_5GCN_CNF_REL_${VER}/nf-services/scripts"

  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${HOST_USER}@${HOST}" bash -se -- "${NF_ROOT}" "${MODE}" "${N3_VAL}" "${N6_VAL}" "${N4_CIDR}" "${AMF_IP}" "${CAP}" "${HOST}" "${VER}" <<'EOSH'
set -euo pipefail
NF_ROOT="$1"; MODE_IN="$2"; N3_IN="$3"; N6_IN="$4"; N4_IN="$5"; AMF_IP="$6"; CAPACITY="$7"; HOST_IP="$8"; VER="$9"

UPF="${NF_ROOT}/upf-1-values.yaml"
SMF="${NF_ROOT}/smf-1-values.yaml"
AMF="${NF_ROOT}/amf-1-values.yaml"
GV="${NF_ROOT}/global-values.yaml"

echo "[remote] NF_ROOT=${NF_ROOT}"
for f in "$UPF" "$SMF" "$AMF" "$GV"; do
  [[ -f "$f" ]] || { echo "[remote] ERROR: missing $f"; exit 3; }
done

# ---- helpers ----
is_pci() { [[ "$1" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-9A-Fa-f]$ ]]; }

resolve_pci() {
  local t="$1"; local bus=""
  if is_pci "$t"; then echo "$t"; return 0; fi
  if [[ -z "${t}" ]]; then echo ""; return 0; fi
  if [[ -d "/sys/class/net/${t}" ]]; then
    if command -v ethtool >/dev/null 2>&1; then
      bus=$(ethtool -i "$t" 2>/dev/null | awk '/bus-info:/ {print $2}') || true
      if is_pci "$bus"; then echo "$bus"; return 0; fi
    fi
    bus=$(basename "$(readlink -f "/sys/class/net/$t/device" 2>/dev/null)" 2>/dev/null) || true
    if is_pci "$bus"; then echo "$bus"; return 0; fi
  fi
  echo ""
}

patch_key_scalar() { # file key value
  awk -v key="$2" -v val="$3" '
    !done && $0 ~ "^[[:space:]]*" key "[[:space:]]*:" {
      i=match($0,/[^[:space:]]/); ind=(i?substr($0,1,i-1):"");
      print ind key ": " val; done=1; next
    } { print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# ---- path-anchored IPAM patchers (update range & exclude in the exact blocks) ----
# UPF (anchored to: upfsp -> n4 -> "ipam")
patch_upf_upfsp_n4_ipam() { # file CIDR excludeIPv4
  awk -v rng="$2" -v exc="$3" '
    function head(line,   i,ind,name){
      i=match(line,/[^[:space:]]/); ind=(i?i-1:0);
      if (match(line,/^[[:space:]]*[A-Za-z0-9_-]+:/)) {
        name=$0; sub(/^[[:space:]]*/,"",name); sub(/:.*/,"",name); return ind "|" name;
      }
      return "-1|";
    }
    BEGIN{in_upfsp=0; in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_exc=0}
    {
      line=$0
      split(head(line),H,"|"); h_ind=H[1]+0; h_name=H[2];

      # upfsp scope
      if (!in_upfsp && h_name=="upfsp"){in_upfsp=1; ind_upfsp=h_ind}
      else if (in_upfsp && h_ind>=0 && h_ind<=ind_upfsp && h_name!="upfsp"){in_upfsp=0; in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_exc=0}

      # n4 scope
      if (in_upfsp){
        if (!in_n4 && h_name=="n4"){in_n4=1; ind_n4=h_ind}
        else if (in_n4 && h_ind>=0 && h_ind<=ind_n4 && h_name!="n4"){in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_exc=0}
      }

      # ipam + range + exclude overwrite
      if (in_upfsp && in_n4){
        if (!in_ipam && line ~ /"ipam"[[:space:]]*:[[:space:]]*\{/) in_ipam=1
        if (in_ipam){
          # range
          if (!in_ranges && line ~ /"ipRanges"[[:space:]]*:[[:space:]]*\[/) in_ranges=1
          if (in_ranges && line ~ /"range"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/){
            i=match(line,/[^[:space:]]/); ind=(i?substr(line,1,i-1):""); trail=""; if (line ~ /",[[:space:]]*$/) trail=","
            print ind "\"range\": \"" rng "\"" trail; next
          }
          if (in_ranges && line ~ /\]/) in_ranges=0

          # exclude (force first item = exc)
          if (!in_ex && line ~ /"exclude"[[:space:]]*:[[:space:]]*\[/){
            in_ex=1
            # remember indent for item lines
            i=match(line,/[^[:space:]]/); exind=(i?substr(line,1,i-1):"") "  "
            print line
            next
          }
          if (in_ex && !wrote_exc && line ~ /"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/){
            trail=""; if (line ~ /",[[:space:]]*$/) trail=","
            print exind "\"" exc "\"" trail
            wrote_exc=1
            next
          }
          # if list empty or first non-IPv4 until closing bracket, inject before ]
          if (in_ex && !wrote_exc && line ~ /^[[:space:]]*\]/){
            print exind "\"" exc "\""
            print line
            in_ex=0; wrote_exc=1; next
          }
          if (in_ex && line ~ /\]/){ in_ex=0 }  # close exclude
          if (in_ipam && !in_ranges && !in_ex && line ~ /\}/){ in_ipam=0 }  # close ipam
        }
      }

      print line
    }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

patch_smf_n4_ipam() { # file CIDR excludeIPv4
  awk -v rng="$2" -v exc="$3" '
    function head(line,   i,ind,name){
      i=match(line,/[^[:space:]]/); ind=(i?i-1:0);
      if (match(line,/^[[:space:]]*[A-Za-z0-9_-]+:/)) {
        name=$0; sub(/^[[:space:]]*/,"",name); sub(/:.*/,"",name); return ind "|" name;
      }
      return "-1|";
    }
    BEGIN{in_top=0; in_mid=0; in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_exc=0}
    {
      line=$0
      split(head(line),H,"|"); h_ind=H[1]+0; h_name=H[2];

      if (!in_top && h_name=="smf-n4iwf"){in_top=1; ind_top=h_ind}
      else if (in_top && h_ind>=0 && h_ind<=ind_top && h_name!="smf-n4iwf"){in_top=0; in_mid=0; in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_exc=0}

      if (in_top){
        if (!in_mid && h_name=="smf_n4iwf"){in_mid=1; ind_mid=h_ind}
        else if (in_mid && h_ind>=0 && h_ind<=ind_mid && h_name!="smf_n4iwf"){in_mid=0; in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_exc=0}
      }

      if (in_mid){
        if (!in_n4 && h_name=="n4"){in_n4=1; ind_n4=h_ind}
        else if (in_n4 && h_ind>=0 && h_ind<=ind_n4 && h_name!="n4"){in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_exc=0}
      }

      if (in_mid && in_n4){
        if (!in_ipam && line ~ /"ipam"[[:space:]]*:[[:space:]]*\{/) in_ipam=1
        if (in_ipam){
          if (!in_ranges && line ~ /"ipRanges"[[:space:]]*:[[:space:]]*\[/) in_ranges=1
          if (in_ranges && line ~ /"range"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/){
            i=match(line,/[^[:space:]]/); ind=(i?substr(line,1,i-1):""); trail=""; if (line ~ /",[[:space:]]*$/) trail=","
            print ind "\"range\": \"" rng "\"" trail; next
          }
          if (in_ranges && line ~ /\]/) in_ranges=0

          if (!in_ex && line ~ /"exclude"[[:space:]]*:[[:space:]]*\[/){
            in_ex=1
            i=match(line,/[^[:space:]]/); exind=(i?substr(line,1,i-1):"") "  "
            print line
            next
          }
          if (in_ex && !wrote_exc && line ~ /"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/){
            trail=""; if (line ~ /",[[:space:]]*$/) trail=","
            print exind "\"" exc "\"" trail
            wrote_exc=1
            next
          }
          if (in_ex && !wrote_exc && line ~ /^[[:space:]]*\]/){
            print exind "\"" exc "\""
            print line
            in_ex=0; wrote_exc=1; next
          }
          if (in_ex && line ~ /\]/){ in_ex=0 }
          if (in_ipam && !in_ranges && !in_ex && line ~ /\}/){ in_ipam=0 }
        }
      }

      print line
    }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
# ---- normalize CRLF ----
sed -i 's/\r$//' "$UPF" "$SMF" "$AMF" "$GV"

# ---- global-values.yaml tweaks ----
patch_key_scalar "$GV" "capacitySetup" "\"${CAPACITY}\""
patch_key_scalar "$GV" "ingressExtFQDN" "${HOST_IP}.nip.io"
if [[ "${CAPACITY}" == "LOW" ]]; then
  patch_key_scalar "$GV" "k8sCpuMgrStaticPolicyEnable" "false"
fi
echo "[remote] global-values.yaml updated."

# ---- bump image tags v1 -> VER in this folder only ----
find "${NF_ROOT}" -maxdepth 1 -type f -name "*.yaml" -print0 | \
  xargs -0 sed -i -E 's/(image:[[:space:]]*"[^"]*:)v1(")/\1'"${VER}"'\2/g'
echo "[remote] replaced image tag v1 -> ${VER} in nf-services/scripts."

# ---- AMF NGC IP under the comment + explicit key fallback ----
if [[ -n "${AMF_IP:-}" && "${AMF_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  awk -v ip="$AMF_IP" '
    { line=$0
      if (mark) {
        if (line ~ /^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+([[:space:]]*#.*)?$/) {
          i=match(line,/[^[:space:]]/); ind=(i?substr(line,1,i-1):"");
          print ind ip; mark=0; next
        }
      }
      if (line ~ /# *NGC IP for external Communication/) { print line; mark=1; next }
      print line
    }' "$AMF" > "$AMF.tmp" && mv "$AMF.tmp" "$AMF"
  sed -i -E 's/^([[:space:]]*externalIP:).*/\1 '"${AMF_IP}"'/' "$AMF"
fi

# ---- UPF intfConfig.type per MODE ----
MODE_UP="$(printf '%s' "${MODE_IN}" | tr '[:lower:]' '[:upper:]')"
if grep -qE '^ *intfConfig:' "$UPF"; then
  if [[ "${MODE_UP}" == "VM" ]]; then
    sed -i -e '/^ *intfConfig:/,/^ *upfsesscoresteps:/{
      s/^\([[:space:]]*type:\).*/\1 "devPassthrough"/
    }' "$UPF"
  else
    sed -i -e '/^ *intfConfig:/,/^ *upfsesscoresteps:/{
      s/^\([[:space:]]*type:\).*/\1 "sriov"/
    }' "$UPF"
  fi
fi

# ---- Resolve N3/N6 to PCI if iface names given ----
N3_PCI="$(resolve_pci "${N3_IN}")"
N6_PCI="$(resolve_pci "${N6_IN}")"

# ---- Inject PCI using sed ranges (BusyBox/GNU sed safe) ----
# N3 within nguInterface: ... up to n6Interface_0:
if [[ -n "${N3_PCI}" ]]; then
  sed -i -e '/^ *nguInterface:/,/^ *n6Interface_0:/{
    s/^\([[:space:]]*pciAddress:\).*/\1 '"${N3_PCI}"'/
  }' "$UPF"
fi

# N6 within n6Interface_0: ... until next header
if [[ -n "${N6_PCI}" ]]; then
  sed -i -e '/^ *n6Interface_0:/,/^ *n6Interface_1:/{
    s/^\([[:space:]]*pciAddress:\).*/\1 '"${N6_PCI}"'/
  }' "$UPF"
  sed -i -e '/^ *n6Interface_0:/,/^ *n9Interface:/{
    s/^\([[:space:]]*pciAddress:\).*/\1 '"${N6_PCI}"'/
  }' "$UPF"
  sed -i -e '/^ *n6Interface_0:/,/^ *upfsesscoresteps:/{
    s/^\([[:space:]]*pciAddress:\).*/\1 '"${N6_PCI}"'/
  }' "$UPF"
fi

# ---- N4 ipam updates (anchored to exact blocks) ----
if [[ -n "${N4_IN:-}" && "${N4_IN}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)\/([0-9]+)$ ]]; then
  base3="${BASH_REMATCH[1]}"; last="${BASH_REMATCH[2]}"; mask="${BASH_REMATCH[3]}"
  N4_RANGE="${base3}.${last}/${mask}"
  EXCL_UPF="${base3}.$((last+1))/32"
  EXCL_SMF="${base3}.$((last+2))/32"

  patch_upf_upfsp_n4_ipam "$UPF" "${N4_RANGE}" "${EXCL_UPF}"
  patch_smf_n4_ipam       "$SMF" "${N4_RANGE}" "${EXCL_SMF}"
  echo "[remote] N4_RANGE=${N4_RANGE}  EXCL_UPF=${EXCL_UPF}  EXCL_SMF=${EXCL_SMF}"
else
  echo "[remote] N4_IN invalid or missing — skipping N4 edits"
fi

# ---- sanity prints (anchored views) ----
echo "[remote] NF checks:"
awk '/# *NGC IP for external Communication/{p=NR+1} NR==p{print "[remote] AMF NGC line: " $0}' "$AMF" || true
grep -nE '^[[:space:]]*externalIP:' "$AMF" | head -1 | sed 's/^/[remote] /' || true
awk '/^ *intfConfig:/{f=1} f&&/^ *type:/{print "[remote] upf.type: "$0; f=0}' "$UPF" || true
awk '/^ *nguInterface:/{f=1} f&&/^ *pciAddress:/{print "[remote] upf.ngu pci: "$0; f=0}' "$UPF" || true
awk '/^ *n6Interface_0:/{f=1} f&&/^ *pciAddress:/{print "[remote] upf.n6  pci: "$0; f=0}' "$UPF" || true

# Show exclude inside UPF → upfsp → n4
awk '
  function hdr(line,   i,ind,name){i=match(line,/[^[:space:]]/);ind=(i?i-1:0);
    if (match(line,/^[[:space:]]*[A-Za-z0-9_-]+:/)) {name=$0; sub(/^[[:space:]]*/,"",name); sub(/:.*/,"",name); return ind "|" name} return "-1|"}
  BEGIN{in_upfsp=0; in_n4=0; in_ex=0; ind_upfsp=-1; ind_n4=-1}
  { line=$0; split(hdr(line),H,"|"); h_ind=H[1]+0; h_name=H[2];
    if (!in_upfsp && h_name=="upfsp"){in_upfsp=1;ind_upfsp=h_ind}
    else if (in_upfsp && h_ind>=0 && h_ind<=ind_upfsp && h_name!="upfsp"){in_upfsp=0;in_n4=0;in_ex=0}
    if (in_upfsp){
      if (!in_n4 && h_name=="n4"){in_n4=1;ind_n4=h_ind}
      else if (in_n4 && h_ind>=0 && h_ind<=ind_n4 && h_name!="n4"){in_n4=0;in_ex=0}
    }
    if (in_upfsp && in_n4){
      if (line ~ /"exclude"[[:space:]]*:[[:space:]]*\[/){in_ex=1; next}
      if (in_ex && line ~ /"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/){print "[remote] upf.exclude(anchor): " line; in_ex=0}
    }
  }' "$UPF" || true

# Show exclude inside SMF → smf-n4iwf → smf_n4iwf → n4
awk '
  function hdr(line,   i,ind,name){i=match(line,/[^[:space:]]/);ind=(i?i-1:0);
    if (match(line,/^[[:space:]]*[A-Za-z0-9_-]+:/)) {name=$0; sub(/^[[:space:]]*/,"",name); sub(/:.*/,"",name); return ind "|" name} return "-1|"}
  BEGIN{in_smfTop=0; in_smf=0; in_n4=0; in_ex=0; ind_smfTop=-1; ind_smf=-1; ind_n4=-1}
  { line=$0; split(hdr(line),H,"|"); h_ind=H[1]+0; h_name=H[2];
    if (!in_smfTop && h_name=="smf-n4iwf"){in_smfTop=1;ind_smfTop=h_ind}
    else if (in_smfTop && h_ind>=0 && h_ind<=ind_smfTop && h_name!="smf-n4iwf"){in_smfTop=0;in_smf=0;in_n4=0;in_ex=0}
    if (in_smfTop){
      if (!in_smf && h_name=="smf_n4iwf"){in_smf=1;ind_smf=h_ind}
      else if (in_smf && h_ind>=0 && h_ind<=ind_smf && h_name!="smf_n4iwf"){in_smf=0;in_n4=0;in_ex=0}
    }
    if (in_smf){
      if (!in_n4 && h_name=="n4"){in_n4=1;ind_n4=h_ind}
      else if (in_n4 && h_ind>=0 && h_ind<=ind_n4 && h_name!="n4"){in_n4=0;in_ex=0}
    }
    if (in_smf && in_n4){
      if (line ~ /"exclude"[[:space:]]*:[[:space:]]*\[/){in_ex=1; next}
      if (in_ex && line ~ /"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/){print "[remote] smf.exclude(anchor): " line; in_ex=0}
    }
  }' "$SMF" || true

grep -nE '"range"|exclude' "$UPF" "$SMF" | sed "s|${NF_ROOT}/||" || true

echo "[remote] ✅ NF config complete on ${HOST_IP}"
EOSH

  echo "[nf_config][${HOST}] ◀ done"
done < "${SERVER_FILE}"

echo "[nf_config] All hosts processed."
