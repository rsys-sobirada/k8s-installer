#!/usr/bin/env bash
# nf_config.sh — configure NF Services YAMLs per CN host
#
# SERVER_FILE line format (colon-separated; one per server):
# name:SERVER_IP:OLD_BUILD_PATH:CN_MODE:N3_PCI_OR_IF:N6_PCI_OR_IF:N4_BASE:AMF_N2_IP
#
# Jenkins exports (required):
#   SERVER_FILE, SSH_KEY, NEW_BUILD_PATH, NEW_VERSION, DEPLOYMENT_TYPE
# Optional overrides: HOST_USER (default root), CN_DEPLOYMENT, N3_PCI, N6_PCI
#
set -euo pipefail

: "${SERVER_FILE:?missing}"
: "${SSH_KEY:?missing}"
: "${NEW_BUILD_PATH:?missing}"
: "${NEW_VERSION:?missing}"
: "${DEPLOYMENT_TYPE:?missing}"

HOST_USER="${HOST_USER:-root}"
OVRD_CN_MODE="${CN_DEPLOYMENT:-}"
OVRD_N3="${N3_PCI:-}"
OVRD_N6="${N6_PCI:-}"

# Version-only (strip tag like _EA3)
VER="${NEW_VERSION%%_*}"

# NF dir: <NEW_BUILD_PATH>/TRILLIUM_5GCN_CNF_REL_<VER>/nf-services/scripts
NF_ROOT_BASE="${NEW_BUILD_PATH%/}/TRILLIUM_5GCN_CNF_REL_${VER}/nf-services/scripts"

# Capacity mapping
case "${DEPLOYMENT_TYPE}" in
  [Ll]ow)    CAP="LOW" ;;
  [Mm]edium) CAP="MEDIUM" ;;
  [Hh]igh)   CAP="HIGH" ;;
  *)         CAP="MEDIUM" ;;
esac

echo "[nf_config] NEW_BUILD_PATH=${NEW_BUILD_PATH}"
echo "[nf_config] NEW_VERSION=${NEW_VERSION} (VER=${VER})"
echo "[nf_config] DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE} (CAP=${CAP})"
echo "[nf_config] SERVER_FILE=${SERVER_FILE}"
echo "[nf_config] NF_ROOT_BASE=${NF_ROOT_BASE}"

trim() { awk '{$1=$1;print}' <<<"${1:-}"; }

# --- robust map parser (safe with colons in PCI) ---
parse_map_line() {
  # IN:  $1 = full colon-separated line
  # OUT: echo "MODE|N3|N6|N4|AMF"
  local line="$1"

  # split by colon
  local IFS=':'; read -r -a T <<< "$line"; IFS=' '

  # must have at least 5 tokens
  if (( ${#T[@]} < 5 )); then
    echo "||||"; return
  fi

  local mode="${T[3]}"

  # find last token that is a CIDR -> N4
  local n4_idx=-1
  for ((i=${#T[@]}-1; i>=0; i--)); do
    if [[ "${T[i]}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
      n4_idx=$i; break
    fi
  done

  local amf_idx=-1
  if (( n4_idx > 0 )); then
    # IPv4 immediately before N4 (optional)
    if [[ "${T[n4_idx-1]}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      amf_idx=$((n4_idx-1))
    fi
  fi

  # middle tokens hold N3/N6 (PCI triples or iface names)
  local m_start=4
  local m_end=$(( (amf_idx>=0 ? amf_idx : n4_idx) - 1 ))
  local n3=""; local n6=""
  local k=$m_start
  local pci_pat='^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$'

  while (( k <= m_end )) ; do
    # try 3-token PCI
    if (( k+2 <= m_end )); then
      local cand="${T[k]}:${T[k+1]}:${T[k+2]}"
      if [[ "${cand}" =~ $pci_pat ]]; then
        if [[ -z "$n3" ]]; then n3="$cand"; k=$((k+3)); continue; fi
        if [[ -z "$n6" ]]; then n6="$cand"; k=$((k+3)); continue; fi
      fi
    fi
    # single-token iface
    if [[ "${T[k]}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      if [[ -z "$n3" ]]; then n3="${T[k]}"; k=$((k+1)); continue; fi
      if [[ -z "$n6" ]]; then n6="${T[k]}"; k=$((k+1)); continue; fi
    fi
    k=$((k+1))
  done

  local n4=""; local amf=""
  (( n4_idx >= 0 ))  && n4="${T[n4_idx]}"
  (( amf_idx >= 0 )) && amf="${T[amf_idx]}"

  echo "${mode}|${n3}|${n6}|${n4}|${amf}"
}

# Collect host IPs (2nd field)
mapfile -t HOSTS < <(awk -F: 'NF && $1 !~ /^#/ {print $2}' "${SERVER_FILE}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
((${#HOSTS[@]})) || { echo "[nf_config] ERROR: no hosts parsed from ${SERVER_FILE}" >&2; exit 2; }

lookup_line_by_ip() { awk -F: -v ip="$2" 'NF && $1 !~ /^#/ && $2==ip {print; exit}' "$1"; }

rc_any=0
for H in "${HOSTS[@]}"; do
  echo "[nf_config][${H}] ▶ start"

  line="$(lookup_line_by_ip "${SERVER_FILE}" "${H}")" || true
  if [[ -z "${line}" ]]; then
    echo "[nf_config][${H}] ERROR: not found in ${SERVER_FILE}" >&2
    rc_any=1; continue
  fi

  parsed="$(parse_map_line "${line}")"
  cn_mode="$(trim "${OVRD_CN_MODE:-$(cut -d'|' -f1 <<<"$parsed")}")"
  n3_arg="$(trim "${OVRD_N3:-$(cut -d'|' -f2 <<<"$parsed")}")"
  n6_arg="$(trim "${OVRD_N6:-$(cut -d'|' -f3 <<<"$parsed")}")"
  n4_base="$(trim "$(cut -d'|' -f4 <<<"$parsed")")"
  amf_ext="$(trim "$(cut -d'|' -f5 <<<"$parsed")")"

  echo "[nf_config][${H}] parsed: MODE='${cn_mode}' N3='${n3_arg}' N6='${n6_arg}' N4='${n4_base}' AMF='${amf_ext}'"

  # Run remote edits
  set +e
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${HOST_USER}@${H}" bash -s -- \
      "${NF_ROOT_BASE}" "${H}" "${CAP}" "${n4_base}" "${cn_mode}" "${n3_arg}" "${n6_arg}" "${VER}" "${amf_ext}" <<'REMOTE'
set -euo pipefail
set -o pipefail

NF_ROOT="${1}"
SERVER_IP="${2}"
CAP="${3}"
N4_BASE="$(echo "${4:-}" | awk '{$1=$1;print}')"
CN_MODE="$(echo "${5:-}" | awk '{print toupper($0)}')"
N3_ARG="${6:-}"
N6_ARG="${7:-}"
NEW_VER="${8:-}"
AMF_EXT="$(echo "${9:-}" | awk '{$1=$1;print}')"

echo "[remote] NF_ROOT=${NF_ROOT}"
test -d "${NF_ROOT}" || { echo "[remote] ERROR: NF path not found: ${NF_ROOT}"; exit 3; }

# ----- helpers -----
file_or_die() { test -f "$1" || { echo "[remote] ERROR: missing $1"; exit 4; }; }
bak() { cp -a "$1" "$1.bak"; }
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; }
pci_pat='^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$'

resolve_pci() {
  local a="$1"
  [[ -z "$a" ]] && { echo ""; return; }
  if [[ "$a" =~ $pci_pat ]]; then echo "$a"; return; fi
  # bond: first slave
  if [[ -f "/sys/class/net/$a/bonding/slaves" ]]; then
    local s; s="$(awk '{print $1; exit}' "/sys/class/net/$a/bonding/slaves" 2>/dev/null || true)"
    [[ -n "$s" && -e "/sys/class/net/$s/device" ]] && { basename "$(readlink -f "/sys/class/net/$s/device")"; return; }
  fi
  # plain iface
  [[ -e "/sys/class/net/$a/device" ]] && { basename "$(readlink -f "/sys/class/net/$a/device")"; return; }
  echo ""
}

# ----- 1) global-values.yaml -----
GV="${NF_ROOT}/global-values.yaml"
file_or_die "${GV}"
bak "${GV}"

# capacitySetup
sed -i -E "s|^([[:space:]]*capacitySetup:[[:space:]]*).*$|\\1\"${CAP}\"|" "${GV}"
# ingressExtFQDN -> <server_ip>.nip.io
sed -i -E "s|^([[:space:]]*ingressExtFQDN:[[:space:]]*).*$|\\1${SERVER_IP}.nip.io|" "${GV}"
# k8sCpuMgrStaticPolicyEnable -> false if LOW
if [[ "${CAP}" == "LOW" ]]; then
  sed -i -E "s|^([[:space:]]*k8sCpuMgrStaticPolicyEnable:[[:space:]]*).*$|\\1false|" "${GV}"
fi
echo "[remote] global-values.yaml updated."

# ----- 2) v1 -> NEW_VER (non-recursive in scripts dir) -----
find "${NF_ROOT}" -maxdepth 1 -type f -print0 | xargs -0 -r sed -i "s/\\bv1\\b/${NEW_VER}/g" || true
echo "[remote] replaced v1 -> ${NEW_VER} in files under nf-services/scripts."

# ----- 3) AMF: externalIP -----
AMF="${NF_ROOT}/amf-1-values.yaml"
if [[ -f "${AMF}" ]]; then
  bak "${AMF}"
  if [[ -n "${AMF_EXT}" ]] && is_ipv4 "${AMF_EXT}"; then
    sed -i -E "s|^([[:space:]]*externalIP:[[:space:]]*).*$|\\1${AMF_EXT}|" "${AMF}"
    echo "[remote] amf-1-values.yaml externalIP = ${AMF_EXT}"
  else
    echo "[remote] amf-1-values.yaml: AMF_N2_IP not provided/invalid — skipped"
  fi
fi

# ----- 4) UPF: devPassthrough & PCI (VM only) -----
UPF="${NF_ROOT}/upf-1-values.yaml"
if [[ -f "${UPF}" ]]; then
  bak "${UPF}"
  if [[ "${CN_MODE}" == "VM" ]]; then
    # Only change type within intfConfig block
    sed -i -E '/^[[:space:]]*intfConfig:/,/^[[:space:]]*[A-Za-z0-9_]+:/{ s/^([[:space:]]*type:[[:space:]]*).*/\1"devPassthrough"/ }' "${UPF}"

    N3_PCI="$(resolve_pci "${N3_ARG}")"
    N6_PCI="$(resolve_pci "${N6_ARG}")"
    echo "[remote] resolved: N3 '${N3_ARG}' -> '${N3_PCI}' ; N6 '${N6_ARG}' -> '${N6_PCI}'"

    # nguInterface pciAddress
    if [[ -n "${N3_PCI}" ]]; then
      sed -i -E '/^[[:space:]]*nguInterface:/,/^[[:space:]]*[A-Za-z0-9_]+:/{ s/^([[:space:]]*pciAddress:[[:space:]]*).*/\1'"${N3_PCI}"'/ }' "${UPF}"
    fi
    # n6Interface_0 pciAddress
    if [[ -n "${N6_PCI}" ]]; then
      sed -i -E '/^[[:space:]]*n6Interface_0:/,/^[[:space:]]*[A-Za-z0-9_]+:/{ s/^([[:space:]]*pciAddress:[[:space:]]*).*/\1'"${N6_PCI}"'/ }' "${UPF}"
    fi

    # quick prints
    awk '/intfConfig:/{f=1} f&&/type:/{print "[remote] upf.type: "$0; f=0}' "${UPF}" || true
    awk '/nguInterface:/, /^[A-Za-z0-9_]+:/{ if($0 ~ /pciAddress:/) print "[remote] upf.ngu pci: "$0 }' "${UPF}" || true
    awk '/n6Interface_0:/, /^[A-Za-z0-9_]+:/{ if($0 ~ /pciAddress:/) print "[remote] upf.n6  pci: "$0 }' "${UPF}" || true
  else
    echo "[remote] upf-1-values.yaml: CN_MODE=${CN_MODE:-unset} -> no PCI/type changes"
  fi
fi

# ----- 5) N4 IPAM (UPF + SMF) -----
if [[ -n "${N4_BASE}" ]] && is_cidr "${N4_BASE}"; then
  base="${N4_BASE%%/*}"
  o1="${base%%.*}"; rem="${base#*.}"
  o2="${rem%%.*}"; rem="${rem#*.}"
  o3="${rem%%.*}"; o4="${rem#*.}"
  ip1="${o1}.${o2}.${o3}.$((10#${o4:-0}+1))"
  ip2="${o1}.${o2}.${o3}.$((10#${o4:-0}+2))"

  if [[ -f "${UPF}" ]]; then
    bak "${UPF}"
    sed -i -E 's|("range"[[:space:]]*:[[:space:]]*")[^"]+(")|\1'"${N4_BASE}"'\2|g' "${UPF}"
    sed -i -E 's|("exclude"[[:space:]]*:[[:space:]]*\[[[:space:]]*")[0-9.]+/32|\1'"${ip1}"'/32|g' "${UPF}"
    grep -n '"range"\|"exclude"' "${UPF}" | sed 's/^/[remote] upf.n4 /'
  fi

  SMF="${NF_ROOT}/smf-1-values.yaml"
  if [[ -f "${SMF}" ]]; then
    bak "${SMF}"
    sed -i -E 's|("range"[[:space:]]*:[[:space:]]*")[^"]+(")|\1'"${N4_BASE}"'\2|g' "${SMF}"
    sed -i -E 's|("exclude"[[:space:]]*:[[:space:]]*\[[[:space:]]*")[0-9.]+/32|\1'"${ip2}"'/32|g' "${SMF}"
    grep -n '"range"\|"exclude"' "${SMF}" | sed 's/^/[remote] smf.n4 /'
  fi
else
  echo "[remote] N4_BASE not provided/invalid — skipping N4 IPAM edits"
fi

echo "[remote] ✅ NF config complete on ${SERVER_IP}"
REMOTE
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    echo "[nf_config][${H}] ❌ failed (rc=${rc})"
    rc_any=1
  else
    echo "[nf_config][${H}] ◀ done"
  fi
done

if [[ $rc_any -ne 0 ]]; then
  echo "[nf_config] One or more hosts failed."
  exit 1
fi

echo "[nf_config] All hosts processed."
