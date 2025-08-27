#!/usr/bin/env bash
# nf_config.sh — configure NF Services YAMLs per CN host
#
# SERVER_FILE line format:
#   name:SERVER_IP:OLD_BUILD_PATH:CN_MODE:N3:N6:N4_BASE:AMF_N2_IP
#
# Jenkins exports:
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

# Version only (strip tag like _EA3)
VER="${NEW_VERSION%%_*}"

# NF dir: <NEW_BUILD_PATH>/TRILLIUM_5GCN_CNF_REL_<VER>/nf-services/scripts
NF_ROOT_BASE="${NEW_BUILD_PATH%/}/TRILLIUM_5GCN_CNF_REL_${VER}/nf-services/scripts"

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

if ((${#HOSTS[@]}==0)); then
  echo "[nf_config] ERROR: no hosts parsed from ${SERVER_FILE}" >&2
  exit 2
fi

lookup_map_line() {
  awk -F: -v ip="$2" 'NF && $1 !~ /^#/ && $2==ip {print; exit}' "$1"
}
extract_field() {
  awk -F: -v idx="$2" '{print $idx}' <<<"$1"
}

rc_any=0
for H in "${HOSTS[@]}"; do
  echo "[nf_config][${H}] start"

  line="$(lookup_map_line "${SERVER_FILE}" "${H}")" || true
  if [[ -z "${line}" ]]; then
    echo "[nf_config][${H}] ERROR: not found in ${SERVER_FILE}" >&2
    rc_any=1; continue
  fi

  cn_mode="$(trim "${OVRD_CN_MODE:-$(extract_field "${line}" 4)}")"
  n3_arg="$(trim "${OVRD_N3:-$(extract_field "${line}" 5)}")"
  n6_arg="$(trim "${OVRD_N6:-$(extract_field "${line}" 6)}")"
  n4_base="$(trim "$(extract_field "${line}" 7)")"
  amf_ext="$(trim "$(extract_field "${line}" 8)")"

  set +e
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${HOST_USER}@${H}" bash -s -- \
      "${NF_ROOT_BASE}" "${H}" "${CAP}" "${n4_base}" "${cn_mode}" "${n3_arg}" "${n6_arg}" "${VER}" "${amf_ext}" <<'REMOTE'
set -euo pipefail

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

# -------------------- helpers --------------------
file_or_die() { test -f "$1" || { echo "[remote] ERROR: missing $1"; exit 4; }; }
bak() { cp -a "$1" "$1.bak"; }

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; }
pci_regex='^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$'

resolve_pci_from_arg() {
  local arg="$1"
  [[ -z "$arg" ]] && { echo ""; return; }
  if [[ "$arg" =~ $pci_regex ]]; then echo "$arg"; return; fi
  # bond: first slave PCI
  if [[ -f "/sys/class/net/$arg/bonding/slaves" ]]; then
    local slave; slave="$(awk '{print $1; exit}' "/sys/class/net/$arg/bonding/slaves" 2>/dev/null || true)"
    if [[ -n "$slave" && -e "/sys/class/net/$slave/device" ]]; then
      basename "$(readlink -f "/sys/class/net/$slave/device")"; return
    fi
  fi
  # normal iface
  if [[ -e "/sys/class/net/$arg/device" ]]; then
    basename "$(readlink -f "/sys/class/net/$arg/device")"; return
  fi
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

# docker registry (from earlier requirement)
sed -i -E "s|^([[:space:]]*registry:[[:space:]]*).*$|\\1rsys-dockerproxy.radisys.com|" "${GV}" || true

# k8sCpuMgrStaticPolicyEnable -> false if LOW
if [[ "${CAP}" == "LOW" ]]; then
  sed -i -E "s|^([[:space:]]*k8sCpuMgrStaticPolicyEnable:[[:space:]]*).*$|\\1false|" "${GV}"
fi
echo "[remote] global-values.yaml updated."

# ---------------- 2) v1 -> NEW_VER (non-recursive) ----------------
find "${NF_ROOT}" -maxdepth 1 -type f -print0 | xargs -0 -r sed -i "s/\\bv1\\b/${NEW_VER}/g" || true
echo "[remote] replaced v1 -> ${NEW_VER} in files under nf-services/scripts."

# ---------------- 3) amf-1-values.yaml: externalIP ----------------
AMF="${NF_ROOT}/amf-1-values.yaml"
if [[ -f "${AMF}" ]]; then
  bak "${AMF}"
  if [[ -n "${AMF_EXT}" && "$(is_ipv4 "${AMF_EXT}"; echo $?)" -eq 0 ]]; then
    sed -i -E "s|^([[:space:]]*externalIP:[[:space:]]*).*$|\\1${AMF_EXT}|" "${AMF}"
    echo "[remote] amf-1-values.yaml externalIP set to ${AMF_EXT}."
  else
    echo "[remote] amf-1-values.yaml: AMF_N2_IP not provided/invalid — skipping."
  fi
fi

# ---------------- 4) upf-1-values.yaml: VM -> devPassthrough & PCI ----------------
UPF="${NF_ROOT}/upf-1-values.yaml"
if [[ -f "${UPF}" ]]; then
  bak "${UPF}"
  if [[ "${CN_MODE}" == "VM" ]]; then
    # Change type only inside intfConfig block
    sed -i -E '/^[[:space:]]*intfConfig:/,/^[[:space:]]*[A-Za-z0-9_]+:/{ s/^([[:space:]]*type:[[:space:]]*).*/\1"devPassthrough"/ }' "${UPF}"

    # Resolve interface names to PCI (or keep PCI if valid)
    N3_PCI="$(resolve_pci_from_arg "${N3_ARG}")"
    N6_PCI="$(resolve_pci_from_arg "${N6_ARG}")"
    echo "[remote] N3='${N3_ARG}' -> PCI='${N3_PCI}' ; N6='${N6_ARG}' -> PCI='${N6_PCI}'"

    # Patch nguInterface
    if [[ -n "${N3_PCI}" ]]; then
      sed -i -E '/^[[:space:]]*nguInterface:/,/^[[:space:]]*[A-Za-z0-9_]+:/{ s/^([[:space:]]*pciAddress:[[:space:]]*).*/\1'"${N3_PCI}"'/ }' "${UPF}"
    fi
    # Patch n6Interface_0
    if [[ -n "${N6_PCI}" ]]; then
      sed -i -E '/^[[:space:]]*n6Interface_0:/,/^[[:space:]]*[A-Za-z0-9_]+:/{ s/^([[:space:]]*pciAddress:[[:space:]]*).*/\1'"${N6_PCI}"'/ }' "${UPF}"
    fi
    echo "[remote] upf-1-values.yaml set devPassthrough; N3=${N3_PCI:-skip} N6=${N6_PCI:-skip}"
  else
    echo "[remote] upf-1-values.yaml: CN_MODE=${CN_MODE:-unset} -> no PCI/type changes."
  fi
fi

# ---------------- 5) N4 IPAM (UPF + SMF) ----------------
if [[ -n "${N4_BASE}" && "$(is_cidr "${N4_BASE}"; echo $?)" -eq 0 ]]; then
  base="${N4_BASE%%/*}"
  o1="${base%%.*}"; r="${base#*.}"
  o2="${r%%.*}";   r="${r#*.}"
  o3="${r%%.*}";   o4="${r#*.}"
  ip1="${o1}.${o2}.${o3}.$((10#${o4:-0}+1))"
  ip2="${o1}.${o2}.${o3}.$((10#${o4:-0}+2))"

  if [[ -f "${UPF}" ]]; then
    bak "${UPF}"
    sed -i -E 's|("range"[[:space:]]*:[[:space:]]*")[^"]+(")|\1'"${N4_BASE}"'\2|g' "${UPF}"
    sed -i -E 's|("exclude"[[:space:]]*:[[:space:]]*\[[[:space:]]*")[0-9.]+/32|\1'"${ip1}"'/32|g' "${UPF}"
    echo "[remote] upf-1-values.yaml N4 updated: range=${N4_BASE}, exclude=${ip1}/32"
  fi

  SMF="${NF_ROOT}/smf-1-values.yaml"
  if [[ -f "${SMF}" ]]; then
    bak "${SMF}"
    sed -i -E 's|("range"[[:space:]]*:[[:space:]]*")[^"]+(")|\1'"${N4_BASE}"'\2|g' "${SMF}"
    sed -i -E 's|("exclude"[[:space:]]*:[[:space:]]*\[[[:space:]]*")[0-9.]+/32|\1'"${ip2}"'/32|g' "${SMF}"
    echo "[remote] smf-1-values.yaml N4 updated: range=${N4_BASE}, exclude=${ip2}/32"
  fi
else
  echo "[remote] N4_BASE not provided/invalid — skipping N4 IPAM edits."
fi

echo "[remote] ✅ NF config complete on ${SERVER_IP}."
REMOTE
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    echo "[nf_config][${H}] ❌ failed (rc=${rc})"
    rc_any=1
  else
    echo "[nf_config][${H}] done"
  fi
done

if [[ $rc_any -ne 0 ]]; then
  echo "[nf_config] One or more hosts failed."
  exit 1
fi

echo "[nf_config] All hosts processed."
