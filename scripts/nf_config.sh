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

# Hosts (field #2 is IP)
mapfile -t HOSTS < <(awk -F: 'NF && $1 !~ /^#/ {print $2}' "${SERVER_FILE}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
((${#HOSTS[@]})) || { echo "[nf_config] ERROR: no hosts parsed from ${SERVER_FILE}" >&2; exit 2; }

lookup_line() { awk -F: -v ip="$2" 'NF && $1 !~ /^#/ && $2==ip {print; exit}' "$1"; }
field() { awk -F: -v i="$2" '{print $i}' <<<"$1"; }

rc_any=0
for H in "${HOSTS[@]}"; do
  echo "[nf_config][${H}] ▶ start"
  line="$(lookup_line "${SERVER_FILE}" "${H}")" || true
  if [[ -z "${line}" ]]; then
    echo "[nf_config][${H}] ERROR: not found in ${SERVER_FILE}" >&2
    rc_any=1; continue
  fi

  cn_mode="$(trim "${OVRD_CN_MODE:-$(field "${line}" 4)}")"
  n3_arg="$(trim "${OVRD_N3:-$(field "${line}" 5)}")"
  n6_arg="$(trim "${OVRD_N6:-$(field "${line}" 6)}")"
  n4_base="$(trim "$(field "${line}" 7)")"
  amf_ext="$(trim "$(field "${line}" 8)")"

  # Run remote edits
  set +e
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${HOST_USER}@${H}" bash -s -- \
      "${NF_ROOT_BASE}" "${H}" "${CAP}" "${n4_base}" "${cn_mode}" "${n3_arg}" "${n6_arg}" "${VER}" "${amf_ext}" <<'REMOTE'
set -euo pipefail
set -o pipefail

NF_ROOT="${1}"
SERVER_IP="${2}"
CAP="${3}"
N4_BASE="$(echo "${4:-}" | awk '{$1=$1;print}')"     # e.g. 10.11.10.0/30
CN_MODE="$(echo "${5:-}" | awk '{print toupper($0)}')" # VM/SRIOV
N3_ARG="${6:-}"    # PCI or iface
N6_ARG="${7:-}"    # PCI or iface
NEW_VER="${8:-}"   # e.g. 6.3.0
AMF_EXT="$(echo "${9:-}" | awk '{$1=$1;print}')"     # IPv4 or empty

echo "[remote] NF_ROOT=${NF_ROOT}"
test -d "${NF_ROOT}" || { echo "[remote] ERROR: NF path not found: ${NF_ROOT}"; exit 3; }

# ---------------- helpers ----------------
file_or_die() { test -f "$1" || { echo "[remote] ERROR: missing $1"; exit 4; }; }
bak() { cp -a "$1" "$1.bak"; }
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }     # syntax only
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

# ---------------- 1) global-values.yaml ----------------
GV="${NF_ROOT}/global-values.yaml"
file_or_die "${GV}"
bak "${GV}"

# capacitySetup
sed -i -E "s|^([[:space:]]*capacitySetup:[[:space:]]*).*$|\\1\"${CAP}\"|" "${GV}"

# ingressExtFQDN -> <server_ip>.nip.io
sed -i -E "s|^([[:space:]]*ingressExtFQDN:[[:space:]]*).*$|\\1${SERVER_IP}.nip.io|" "${GV}"

# registry override (from earlier requirement)
sed -i -E "s|^([[:space:]]*registry:[[:space:]]*).*$|\\1rsys-dockerproxy.radisys.com|" "${GV}" || true

# k8sCpuMgrStaticPolicyEnable -> false if LOW
if [[ "${CAP}" == "LOW" ]]; then
  sed -i -E "s|^([[:space:]]*k8sCpuMgrStaticPolicyEnable:[[:space:]]*).*$|\\1false|" "${GV}"
fi
echo "[remote] global-values.yaml updated."

# ---------------- 2) v1 -> NEW_VER (in files under scripts/) ----------------
find "${NF_ROOT}" -maxdepth 1 -type f -print0 | xargs -0 -r sed -i "s/\\bv1\\b/${NEW_VER}/g" || true
echo "[remote] replaced v1 -> ${NEW_VER} in files under nf-services/scripts."

# ---------------- 3) amf-1-values.yaml: externalIP ----------------
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

# ---------------- 4) upf-1-values.yaml: devPassthrough & PCI (VM only) ----------------
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

    # Show final lines for quick verification
    awk '/intfConfig:/{f=1} f&&/type:/{print "[remote] upf.type: "$0; f=0}' "${UPF}" || true
    awk '/nguInterface:/, /^[A-Za-z0-9_]+:/{ if($0 ~ /pciAddress:/) print "[remote] upf.ngu pci: "$0 }' "${UPF}" || true
    awk '/n6Interface_0:/, /^[A-Za-z0-9_]+:/{ if($0 ~ /pciAddress:/) print "[remote] upf.n6  pci: "$0 }' "${UPF}" || true
  else
    echo "[remote] upf-1-values.yaml: CN_MODE=${CN_MODE:-unset} -> no PCI/type changes"
  fi
fi

# ---------------- 5) N4 IPAM (UPF + SMF) ----------------
if [[ -n "${N4_BASE}" ]] && is_cidr "${N4_BASE}"; then
  base="${N4_BASE%%/*}"
  o1="${base%%.*}"; rem="${base#*.}"
  o2="${rem%%.*}"; rem="${rem#*.}"
  o3="${rem%%.*}"; o4="${rem#*.}"
  ip1="${o1}.${o2}.${o3}.$((10#${o4:-0}+1))"
  ip2="${o1}.${o2}.${o3}.$((10#${o4:-0}+2))"

  # UPF n4 range/exclude
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
