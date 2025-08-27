#!/usr/bin/env bash
# nf_config.sh — configure NF Services YAMLs on one or more CNs
# Inputs (exported by Jenkins):
#   SERVER_FILE, SSH_KEY, NEW_BUILD_PATH, NEW_VERSION, DEPLOYMENT_TYPE
# Optional: HOST_USER
set -euo pipefail

: "${SERVER_FILE:?missing}"
: "${SSH_KEY:?missing}"
: "${NEW_BUILD_PATH:?missing}"
: "${NEW_VERSION:?missing}"
: "${DEPLOYMENT_TYPE:?missing}"
HOST_USER="${HOST_USER:-root}"

VER="${NEW_VERSION%%_*}"   # 6.3.0 from 6.3.0_EA3
case "${DEPLOYMENT_TYPE}" in
  [Ll]ow) CAP="LOW" ;;
  [Hh]igh) CAP="HIGH" ;;
  *) CAP="MEDIUM" ;;
esac

echo "[nf_config] NEW_BUILD_PATH=${NEW_BUILD_PATH}"
echo "[nf_config] NEW_VERSION=${NEW_VERSION} (VER=${VER})"
echo "[nf_config] DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE} (CAP=${CAP})"
echo "[nf_config] SERVER_FILE=${SERVER_FILE}"

# -------- helpers used later on remote side --------
remote_script='
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

is_pci() { [[ "$1" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$ ]]; }
resolve_pci() {
  local t="$1"
  if is_pci "$t"; then echo "$t"; return 0; fi
  if [[ -n "$t" && -d "/sys/class/net/$t" ]]; then
    local bus=""
    bus=$(ethtool -i "$t" 2>/dev/null | awk '"'"'/bus-info:/ {print $2}'"'"') || true
    if is_pci "$bus"; then echo "$bus"; return 0; fi
    bus=$(basename "$(readlink -f "/sys/class/net/$t/device" 2>/dev/null)" 2>/dev/null) || true
    if is_pci "$bus"; then echo "$bus"; return 0; fi
  fi
  echo ""
}

patch_ipam_range_ipv4() {  # $1 file, $2 A.B.C.D/M
  local f="$1" rng="$2"
  awk -v rng="$rng" '"'"'
    BEGIN{in_ipam=0; in_ranges=0; done=0}
    {
      line=$0
      if (line ~ /"ipam"[[:space:]]*:[[:space:]]*\{/) in_ipam=1
      if (in_ipam && line ~ /"ipRanges"[[:space:]]*:[[:space:]]*\[/) in_ranges=1
      if (in_ranges && !done && line ~ /"range":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/) {
        sub(/"range":[[:space:]]*"[^"]+"/, "\"range\": \"" rng "\"", line); done=1
      }
      print line
      if (in_ranges && line ~ /\]/) in_ranges=0
      if (in_ipam   && line ~ /\}/ && !in_ranges) in_ipam=0
    }'"'"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

patch_ipam_exclude_ipv4() { # $1 file, $2 A.B.C.D/32
  local f="$1" exc="$2"
  awk -v exc="$exc" '"'"'
    BEGIN{in_ipam=0; in_exc=0; done=0}
    {
      line=$0
      if (line ~ /"ipam"[[:space:]]*:[[:space:]]*\{/) in_ipam=1
      if (in_ipam && line ~ /"exclude"[[:space:]]*:[[:space:]]*\[/) in_exc=1
      if (in_exc && !done && line ~ /"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/32"/) {
        sub(/"[0-9]+\.[0-9]+\.[0-9]+\/32"/, "\"" exc "\"", line); done=1
      }
      print line
      if (in_exc && line ~ /\]/) in_exc=0
      if (in_ipam && line ~ /\}/ && !in_exc) in_ipam=0
    }'"'"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ----- global-values.yaml
sed -ri '"'"'s|^(\s*capacitySetup:\s*).*$|\1"'"'"'"${CAPACITY}"'"'"'"|'\""$GV"\""
sed -ri '"'"'s|^(\s*ingressExtFQDN:\s*).*$|\1'"'"'"${HOST_IP}.nip.io"'"'"'|'\""$GV"\""
if [[ "${CAPACITY}" == "LOW" ]]; then
  sed -ri '"'"'s|^(\s*k8sCpuMgrStaticPolicyEnable:\s*).*$|\1false|'\""$GV"\""
fi
echo "[remote] global-values.yaml updated."

# ----- version bump v1 -> VER
find "${NF_ROOT}" -maxdepth 1 -type f -name "*.yaml" -print0 | xargs -0 sed -i -E "s/\\bv1\\b/${VER}/g"
echo "[remote] replaced v1 -> ${VER} in files under nf-services/scripts."

# ----- AMF externalIP
if [[ -n "${AMF_IP:-}" && "${AMF_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  sed -ri '"'"'s|^(\s*externalIP:\s*).*$|\1'"'"'"${AMF_IP}"'"'"'|'\""$AMF"\""
else
  echo "[remote] amf-1-values.yaml: AMF_N2_IP not provided/invalid — skipped"
fi

# ----- UPF intfConfig.type & PCI
MODE_UP=$(tr '"'"'[:lower:]'"'"' '"'"'[:upper:]'"'"' <<<"${MODE_IN:-}")
if [[ "${MODE_UP}" == "VM" ]]; then
  sed -ri '"'"'/^ *intfConfig:/,/^ *upfsesscoresteps:/ s/^(\s*type:\s*).*/\1"devPassthrough"/'\""$UPF"\""
else
  sed -ri '"'"'/^ *intfConfig:/,/^ *upfsesscoresteps:/ s/^(\s*type:\s*).*/\1"sriov"/'\""$UPF"\""
fi

N3_PCI="$(resolve_pci "${N3_IN:-}")"
N6_PCI="$(resolve_pci "${N6_IN:-}")"

if [[ -n "${N3_PCI}" ]]; then
  sed -ri '"'"'/^ *nguInterface:/,/^ *n6Interface_0:/ s/^(\s*pciAddress:\s*).*/\1'"'"'"${N3_PCI}"'"'"'/'\""$UPF"\""
fi
if [[ -n "${N6_PCI}" ]]; then
  sed -ri '"'"'/^ *n6Interface_0:/,/^ *n6Interface_1:|^ *n9Interface:|^ *upfsesscoresteps:/ s/^(\s*pciAddress:\s*).*/\1'"'"'"${N6_PCI}"'"'"'/'\""$UPF"\""
fi

# ----- N4 range & excludes (UPF .1, SMF .2)
if [[ -n "${N4_IN:-}" && "${N4_IN}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)\/([0-9]+)$ ]]; then
  base3="${BASH_REMATCH[1]}"; last="${BASH_REMATCH[2]}"; mask="${BASH_REMATCH[3]}"
  N4_RANGE="${base3}.${last}/${mask}"
  EXCL_UPF="${base3}.$((last+1))/32"
  EXCL_SMF="${base3}.$((last+2))/32"

  patch_ipam_range_ipv4   "$UPF" "${N4_RANGE}"
  patch_ipam_range_ipv4   "$SMF" "${N4_RANGE}"
  patch_ipam_exclude_ipv4 "$UPF" "${EXCL_UPF}"
  patch_ipam_exclude_ipv4 "$SMF" "${EXCL_SMF}"
  echo "[remote] N4_RANGE=${N4_RANGE}  EXCL_UPF=${EXCL_UPF}  EXCL_SMF=${EXCL_SMF}"
else
  echo "[remote] N4_BASE not provided/invalid — skipping N4 IPAM edits"
fi

# ----- quick checks
echo "[remote] NF checks:"
grep -n '"'"'externalIP:'"'"' "${AMF}" || true
sed -n '"'"'/^ *intfConfig:/,/^ *upfsesscoresteps:/p'"'"' "${UPF}" | awk '"'"'/^ *type:/{print "[remote] upf.type: "$0; exit}'"'"'
sed -n '"'"'/^ *nguInterface:/,/^ *n6Interface_0:/p'"'"' "${UPF}" | awk '"'"'/pciAddress:/{print "[remote] upf.ngu pci: "$0; exit}'"'"'
sed -n '"'"'/^ *n6Interface_0:/,/^ *n6Interface_1:|^ *n9Interface:|^ *upfsesscoresteps:/p'"'"' "${UPF}" | awk '"'"'/pciAddress:/{print "[remote] upf.n6  pci: "$0; exit}'"'"'
grep -nE '"'"'\"range\"|exclude'"'"' "${UPF}" "${SMF}" | sed "s|${NF_ROOT}/||"
echo "[remote] ✅ NF config complete on ${HOST_IP}"
'

# -------- read and parse server lines robustly (PCIs contain :)
mapfile -t MAPLINES < <(awk 'NF && $1 !~ /^#/' "${SERVER_FILE}")
for RAW in "${MAPLINES[@]}"; do
  LINE="$(echo "$RAW" | tr -d "[:space:]")"
  # name:ip:build:mode:rest
  IFS=':' read -r NAME HOST OLD_BUILD MODE REST <<<"$LINE" || true
  [[ -n "${HOST:-}" && -n "${REST:-}" ]] || { echo "[nf_config] skip bad line: $RAW"; continue; }

  # from right: ... : N4 : AMF
  AMF_N2_IP="${REST##*:}"; REST="${REST%:*}"
  N4_BASE="${REST##*:}";   REST="${REST%:*}"

  # remainder is N3:N6 (may be PCI or iface). If both PCI, match them; else split once.
  if [[ "$REST" =~ ^([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]):([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F])$ ]]; then
    N3_RAW="${BASH_REMATCH[1]}"; N6_RAW="${BASH_REMATCH[2]}"
  else
    IFS=':' read -r N3_RAW N6_RAW <<<"$REST"
  fi

  echo "[nf_config][${HOST}] ▶ start"
  echo "[nf_config][${HOST}] parsed: MODE='${MODE}' N3='${N3_RAW}' N6='${N6_RAW}' N4='${N4_BASE}' AMF='${AMF_N2_IP}'"

  NF_ROOT="${NEW_BUILD_PATH%/}/TRILLIUM_5GCN_CNF_REL_${VER}/nf-services/scripts"

  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${HOST_USER}@${HOST}" \
      bash -euo pipefail -s -- \
      "${NF_ROOT}" "${MODE:-}" "${N3_RAW:-}" "${N6_RAW:-}" "${N4_BASE:-}" "${AMF_N2_IP:-}" "${CAP}" "${HOST}" "${VER}" \
      <<<"$remote_script"

  echo "[nf_config][${HOST}] ◀ done"
done

echo "[nf_config] All hosts processed."
