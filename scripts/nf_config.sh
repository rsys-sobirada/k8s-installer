#!/usr/bin/env bash
# nf_config.sh — configure NF Services YAMLs per CN host
#
# Inputs (exported by Jenkins):
#   SERVER_FILE          (required) -> colon file: name:SERVER_IP:OLD_BUILD_PATH:CN_MODE:N3:N6:N4_BASE:AMF_N2_IP
#   SSH_KEY              (required) -> Jenkins node private key path
#   NEW_BUILD_PATH       (required) -> e.g. /home/labadmin/6.3.0/EA3
#   NEW_VERSION          (required) -> e.g. 6.3.0_EA3  (we use 6.3.0)
#   DEPLOYMENT_TYPE      (required) -> Low|Medium|High
# Optional overrides (if set, they override map values):
#   HOST_USER (default root), CN_DEPLOYMENT, N3_PCI, N6_PCI
#
# Effects on each host:
#   - Edits ${NEW_BUILD_PATH}/TRILLIUM_5GCN_CNF_REL_<VER>/nf-services/scripts/*
#   - global-values.yaml: capacitySetup=<CAP>; ingressExtFQDN=<SERVER_IP>.nip.io; k8sCpuMgrStaticPolicyEnable=false if CAP=LOW
#   - amf-1-values.yaml: externalIP=<AMF_N2_IP> (if provided)
#   - upf-1-values.yaml (CN_MODE=VM): type="devPassthrough"; set pciAddress for nguInterface/n6Interface_0
#       * N3/N6 may be PCI "0000:BB:DD.F" or interface name (ens7f0, bond0, ...); interface is resolved to PCI on the host
#   - N4 IPAM: upf-1-values.yaml range=N4_BASE, exclude=base+1; smf-1-values.yaml range=N4_BASE, exclude=base+2
#   - Replace word-boundary v1 -> <VER> in files directly under nf-services/scripts (non-recursive)
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

# NF root path: <NEW_BUILD_PATH>/TRILLIUM_5GCN_CNF_REL_<VER>/nf-services/scripts
NF_ROOT_BASE="${NEW_BUILD_PATH%/}/TRILLIUM_5GCN_CNF_REL_${VER}/nf-services/scripts"

# CAP mapping
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

# ---------- helpers on Jenkins node ----------
trim() { awk '{$1=$1;print}' <<<"${1:-}"; }

# get hosts (field #2 = IP)
mapfile -t HOSTS < <(awk -F: 'NF && $1 !~ /^#/ {print $2}' "${SERVER_FILE}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' )

if ((${#HOSTS[@]}==0)); then
  echo "[nf_config] ERROR: no hosts parsed from ${SERVER_FILE}" >&2
  exit 2
fi

lookup_map_line() {
  # $1 = map file, $2 = ip, prints first matching line
  awk -F: -v ip="$2" 'NF && $1 !~ /^#/ && $2==ip {print; exit}' "$1"
}

extract_field() {
  # $1 = colon-line, $2 = index (1-based)
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

  # Map fields (with overrides when provided)
  cn_mode="$(trim "${OVRD_CN_MODE:-$(extract_field "${line}" 4)}")"
  n3_arg="$(trim "${OVRD_N3:-$(extract_field "${line}" 5)}")"
  n6_arg="$(trim "${OVRD_N6:-$(extract_field "${line}" 6)}")"
  n4_base="$(trim "$(extract_field "${line}" 7)")"
  amf_ext="$(trim "$(extract_field "${line}" 8)")"

  # Remote execute: pass all args (use defaults on the remote)
  set +e
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${HOST_USER}@${H}" bash -s -- \
      "${NF_ROOT_BASE}" "${H}" "${CAP}" "${n4_base}" "${cn_mode}" "${n3_arg}" "${n6_arg}" "${VER}" "${amf_ext}" <<'REMOTE'
set -euo pipefail

NF_ROOT_BASE="${1}"      # e.g. /home/labadmin/6.3.0/EA3/TRILLIUM_5GCN_CNF_REL_6.3.0/nf-services/scripts
SERVER_IP="${2}"
CAP="${3}"               # LOW/MEDIUM/HIGH
N4_BASE="$(echo "${4:-}" | awk '{$1=$1;print}')"   # trim
CN_MODE="$(echo "${5:-}" | awk '{print toupper($0)}')"  # VM/SRIOV/empty
N3_ARG="${6:-}"
N6_ARG="${7:-}"
NEW_VER="${8:-}"         # 6.3.0
AMF_EXT="$(echo "${9:-}" | awk '{$1=$1;print}')"   # trim

echo "[remote] NF_ROOT=${NF_ROOT_BASE}"
test -d "${NF_ROOT_BASE}" || { echo "[remote] ERROR: NF path not found: ${NF_ROOT_BASE}"; exit 3; }

# --- helpers ---
file_or_die() { test -f "$1" || { echo "[remote] ERROR: missing $1"; exit 4; }; }
bak() { cp -a "$1" "$1.bak"; }

# Resolve interface -> PCI (or keep PCI if already valid)
pci_regex='^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$'
resolve_pci_from_arg() {
  local arg="$1"
  [[ -z "$arg" ]] && { echo ""; return; }
  if [[ "$arg" =~ $pci_regex ]]; then echo "$arg"; return; fi
  # bond: take first slave
  if [[ -f "/sys/class/net/$arg/bonding/slaves" ]]; then
    local slave; slave="$(awk '{print $1; exit}' "/sys/class/net/$arg/bonding/slaves" 2>/dev/null || true)"
    if [[ -n "$slave" && -e "/sys/class/net/$slave/device" ]]; then
      basename "$(readlink -f "/sys/class/net/$slave/device")"; return
    fi
  fi
  # plain interface
  if [[ -e "/sys/class/net/$arg/device" ]]; then
    basename "$(readlink -f "/sys/class/net/$arg/device")"; return
  fi
  echo ""
}

N3_PCI="$(resolve_pci_from_arg "${N3_ARG}")"
N6_PCI="$(resolve_pci_from_arg "${N6_ARG}")"
echo "[remote] N3='${N3_ARG}' -> PCI='${N3_PCI}' ; N6='${N6_ARG}' -> PCI='${N6_PCI}'"

# ---------- 1) global-values.yaml ----------
GV="${NF_ROOT_BASE}/global-values.yaml"
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

# ---------- 2) Replace v1 -> NEW_VER in this directory (files only) ----------
find "${NF_ROOT_BASE}" -maxdepth 1 -type f -print0 | xargs -0 -r sed -i "s/\\bv1\\b/${NEW_VER}/g" || true
echo "[remote] replaced v1 -> ${NEW_VER} in files under nf-services/scripts."

# ---------- 3) amf-1-values.yaml: externalIP (if provided) ----------
AMF="${NF_ROOT_BASE}/amf-1-values.yaml"
if [[ -f "${AMF}" ]]; then
  bak "${AMF}"
  if [[ -n "${AMF_EXT}" ]]; then
    sed -i -E "s|^([[:space:]]*externalIP:[[:space:]]*).*$|\\1${AMF_EXT}|" "${AMF}"
    echo "[remote] amf-1-values.yaml externalIP set to ${AMF_EXT}."
  else
    echo "[remote] amf-1-values.yaml present but AMF_N2_IP not provided — skipping."
  fi
fi

# ---------- 4) upf-1-values.yaml: devPassthrough & PCI (only for VM) ----------
UPF="${NF_ROOT_BASE}/upf-1-values.yaml"
if [[ -f "${UPF}" ]]; then
  bak "${UPF}"
  if [[ "${CN_MODE}" == "VM" ]]; then
    # Force intfConfig.type to "devPassthrough" (only within intfConfig block)
    awk -v RS= -v ORS="" '
      {
        gsub(/\n([[:space:]]*)type:[[:space:]]*".*"/,"\n\\1type: \"devPassthrough\"");
        print
      }' "${UPF}.bak" > "${UPF}"

    # Update pciAddress for nguInterface and n6Interface_0 if we have resolved PCIs
    awk -v n3="'${N3_PCI}'" -v n6="'${N6_PCI}'" '
      BEGIN{sec=""}
      /[[:space:]]+nguInterface:/      {sec="ngu"}
      /[[:space:]]+n6Interface_0:/     {sec="n6"}
      /^[[:space:]]+[A-Za-z0-9_]+:/ && $0 !~ /nguInterface:|n6Interface_0:/ { sec="" }
      {
        if ($0 ~ /^[[:space:]]*pciAddress:/ && sec=="ngu" && n3!="") sub(/pciAddress:.*/,"pciAddress: " n3)
        else if ($0 ~ /^[[:space:]]*pciAddress:/ && sec=="n6" && n6!="") sub(/pciAddress:.*/,"pciAddress: " n6)
        print
      }' "${UPF}" > "${UPF}.tmp" && mv "${UPF}.tmp" "${UPF}"
    echo "[remote] upf-1-values.yaml set devPassthrough; N3=${N3_PCI:-skip} N6=${N6_PCI:-skip}"
  else
    echo "[remote] upf-1-values.yaml: CN_MODE=${CN_MODE:-unset} -> no PCI/type changes."
  fi
fi

# ---------- 5) N4 IPAM in UPF/SMF ----------
# N4_BASE like 10.11.10.0/30 -> base+1 for UPF exclude, base+2 for SMF exclude
if [[ -n "${N4_BASE}" ]]; then
  base="${N4_BASE%%/*}"
  mask="${N4_BASE#*/}"
  # parse octets
  o1="${base%%.*}"; r="${base#*.}"
  o2="${r%%.*}";   r="${r#*.}"
  o3="${r%%.*}";   o4="${r#*.}"
  ip1="${o1}.${o2}.${o3}.$((10#${o4:-0}+1))"
  ip2="${o1}.${o2}.${o3}.$((10#${o4:-0}+2))"

  if [[ -f "${UPF}" ]]; then
    bak "${UPF}"
    sed -i -E "s|(\"range\"[[:space:]]*:[[:space:]]*\")[0-9.]+/[0-9]+(\")|\\1${N4_BASE}\\2|g" "${UPF}"
    sed -i -E "s|(\"exclude\"[[:space:]]*:[[:space:]]*\\[[[:space:]]*\")[0-9.]+/32|\\1${ip1}/32|g" "${UPF}"
    echo "[remote] upf-1-values.yaml N4 updated: range=${N4_BASE}, exclude=${ip1}/32"
  fi

  SMF="${NF_ROOT_BASE}/smf-1-values.yaml"
  if [[ -f "${SMF}" ]]; then
    bak "${SMF}"
    sed -i -E "s|(\"range\"[[:space:]]*:[[:space:]]*\")[0-9.]+/[0-9]+(\")|\\1${N4_BASE}\\2|g" "${SMF}"
    sed -i -E "s|(\"exclude\"[[:space:]]*:[[:space:]]*\\[[[:space:]]*\")[0-9.]+/32|\\1${ip2}/32|g" "${SMF}"
    echo "[remote] smf-1-values.yaml N4 updated: range=${N4_BASE}, exclude=${ip2}/32"
  fi
else
  echo "[remote] N4_BASE not provided — skipping N4 IPAM edits."
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
