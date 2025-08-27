#!/usr/bin/env bash
# nf_config.sh — configure NF Services YAMLs per CN host
# Line format (NO SPACES):
# name:SERVER_IP:OLD_BUILD_PATH:CN_MODE:N3_PCI_OR_IF:N6_PCI_OR_IF:N4_CIDR:AMF_N2_IP
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

VER="${NEW_VERSION%%_*}"
NF_ROOT_BASE="${NEW_BUILD_PATH%/}/TRILLIUM_5GCN_CNF_REL_${VER}/nf-services/scripts"

case "${DEPLOYMENT_TYPE}" in
  [Ll]ow) CAP="LOW" ;;
  [Mm]edium) CAP="MEDIUM" ;;
  [Hh]igh) CAP="HIGH" ;;
  *) CAP="MEDIUM" ;;
esac

echo "[nf_config] NEW_BUILD_PATH=${NEW_BUILD_PATH}"
echo "[nf_config] NEW_VERSION=${NEW_VERSION} (VER=${VER})"
echo "[nf_config] DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE} (CAP=${CAP})"
echo "[nf_config] SERVER_FILE=${SERVER_FILE}"
echo "[nf_config] NF_ROOT_BASE=${NF_ROOT_BASE}"

is_ipv4(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_cidr(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; }

# Robust parse that understands PCIs (with colons)
parse_map_line() {
  local line="$1"
  awk -v L="$line" '
    BEGIN {
      # name:ip:path:mode:N3:N6:cidr:amf
      re="^([^:]+):" \
         "([^:]+):" \
         "([^:]+):" \
         "(VM|SRIOV):" \
         "([0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\\.[0-7]|[A-Za-z0-9_.-]+):" \
         "([0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\\.[0-7]|[A-Za-z0-9_.-]+):" \
         "(([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}):" \
         "(([0-9]{1,3}\\.){3}[0-9]{1,3})$";
      if (L ~ re) {
        match(L, re, a);
        # a[4]=mode a[5]=N3 a[6]=N6 a[7]=CIDR a[9]=AMF
        printf "%s|%s|%s|%s|%s\n", a[4], a[5], a[6], a[7], a[9];
      }
    }
  '
}

# collect host IPs (2nd field)
mapfile -t HOSTS < <(awk -F: 'NF && $1 !~ /^#/ {print $2}' "${SERVER_FILE}")
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
  if [[ -z "${parsed}" ]]; then
    echo "[nf_config][${H}] ERROR: could not parse map line: ${line}" >&2
    rc_any=1; continue
  fi

  cn_mode="${OVRD_CN_MODE:-$(cut -d'|' -f1 <<<"$parsed")}"
  n3_arg="${OVRD_N3:-$(cut -d'|' -f2 <<<"$parsed")}"
  n6_arg="${OVRD_N6:-$(cut -d'|' -f3 <<<"$parsed")}"
  n4_base="$(cut -d'|' -f4 <<<"$parsed")"
  amf_ext="$(cut -d'|' -f5 <<<"$parsed")"
  echo "[nf_config][${H}] parsed: MODE='${cn_mode}' N3='${n3_arg}' N6='${n6_arg}' N4='${n4_base}' AMF='${amf_ext}'"

  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${HOST_USER}@${H}" bash -s -- \
      "${NF_ROOT_BASE}" "${H}" "${CAP}" "${n4_base}" "${cn_mode}" "${n3_arg}" "${n6_arg}" "${VER}" "${amf_ext}" <<'REMOTE'
set -euo pipefail
set -o pipefail

NF_ROOT="${1}"
SERVER_IP="${2}"
CAP="${3}"
N4_BASE="${4}"
CN_MODE="$(echo "${5:-}" | awk '{print toupper($0)}')"
N3_ARG="${6:-}"
N6_ARG="${7:-}"
NEW_VER="${8:-}"
AMF_EXT="${9:-}"

# helpers
file_or_die() { test -f "$1" || { echo "[remote] ERROR: missing $1"; exit 4; }; }
bak() { cp -a "$1" "$1.bak"; }
pci_pat='^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$'
is_ipv4(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_cidr(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; }
resolve_pci() {
  local a="$1"
  [[ -z "$a" ]] && { echo ""; return; }
  if [[ "$a" =~ $pci_pat ]]; then echo "$a"; return; fi
  # interface or bond -> first slave
  if [[ -f "/sys/class/net/$a/bonding/slaves" ]]; then
    local s; s="$(awk '{print $1; exit}' "/sys/class/net/$a/bonding/slaves" 2>/dev/null || true)"
    [[ -n "$s" && -e "/sys/class/net/$s/device" ]] && { basename "$(readlink -f "/sys/class/net/$s/device")"; return; }
  fi
  [[ -e "/sys/class/net/$a/device" ]] && { basename "$(readlink -f "/sys/class/net/$a/device")"; return; }
  echo ""
}

echo "[remote] NF_ROOT=${NF_ROOT}"
test -d "${NF_ROOT}" || { echo "[remote] ERROR: NF path not found: ${NF_ROOT}"; exit 3; }

# 1) global-values.yaml
GV="${NF_ROOT}/global-values.yaml"
file_or_die "${GV}"; bak "${GV}"
sed -i -E "s|^([[:space:]]*capacitySetup:[[:space:]]*).*$|\\1\"${CAP}\"|" "${GV}"
sed -i -E "s|^([[:space:]]*ingressExtFQDN:[[:space:]]*).*$|\\1${SERVER_IP}.nip.io|" "${GV}"
if [[ "${CAP}" == "LOW" ]]; then
  sed -i -E "s|^([[:space:]]*k8sCpuMgrStaticPolicyEnable:[[:space:]]*).*$|\\1false|" "${GV}"
fi
echo "[remote] global-values.yaml updated."

# 2) v1 -> NEW_VER (only files in scripts dir)
find "${NF_ROOT}" -maxdepth 1 -type f -print0 | xargs -0 -r sed -i "s/\\bv1\\b/${NEW_VER}/g" || true
echo "[remote] replaced v1 -> ${NEW_VER} in files under nf-services/scripts."

# 3) AMF external IP
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

# 4) UPF: type & PCI when VM
UPF="${NF_ROOT}/upf-1-values.yaml"
if [[ -f "${UPF}" ]]; then
  bak "${UPF}"
  if [[ "${CN_MODE}" == "VM" ]]; then
    # type -> devPassthrough inside intfConfig block
    sed -i -E '/^[[:space:]]*intfConfig:/,/^[[:space:]]*[A-Za-z0-9_]+:/{ s/^([[:space:]]*type:[[:space:]]*).*/\1"devPassthrough"/ }' "${UPF}"

    N3_PCI="$(resolve_pci "${N3_ARG}")"
    N6_PCI="$(resolve_pci "${N6_ARG}")"

    if [[ -n "${N3_PCI}" ]]; then
      awk -v pci="${N3_PCI}" '
        BEGIN{in=0}
        /^[[:space:]]*nguInterface:/ {in=1}
        (/^[[:space:]]*n6Interface_0:/ || /^[[:space:]]*n6Interface_1:/ || /^[[:space:]]*n9Interface:/ || /^[[:space:]]*upfsesscoresteps:/) {in=0}
        { if(in && $0 ~ /^[[:space:]]*pciAddress:[[:space:]]*/) { sub(/pciAddress:.*/, "pciAddress: " pci); in=0 } print }
      ' "${UPF}" > "${UPF}.tmp" && mv "${UPF}.tmp" "${UPF}"
    fi

    if [[ -n "${N6_PCI}" ]]; then
      awk -v pci="${N6_PCI}" '
        BEGIN{in=0}
        /^[[:space:]]*n6Interface_0:/ {in=1}
        (/^[[:space:]]*n6Interface_1:/ || /^[[:space:]]*n9Interface:/ || /^[[:space:]]*upfsesscoresteps:/) {in=0}
        { if(in && $0 ~ /^[[:space:]]*pciAddress:[[:space:]]*/) { sub(/pciAddress:.*/, "pciAddress: " pci); in=0 } print }
      ' "${UPF}" > "${UPF}.tmp" && mv "${UPF}.tmp" "${UPF}"
    fi

    awk '/intfConfig:/{f=1} f&&/type:/{print "[remote] upf.type: "$0; f=0}' "${UPF}" || true
    awk '/nguInterface:/, /^[A-Za-z0-9_]+:/{ if($0 ~ /pciAddress:/) print "[remote] upf.ngu pci: "$0 }' "${UPF}" || true
    awk '/n6Interface_0:/, /^[A-Za-z0-9_]+:/{ if($0 ~ /pciAddress:/) print "[remote] upf.n6  pci: "$0 }' "${UPF}" || true
  else
    echo "[remote] upf-1-values.yaml: CN_MODE=${CN_MODE:-unset} -> no PCI/type changes"
  fi
fi

# 5) N4 IPAM (UPF + SMF)
if [[ -n "${N4_BASE}" ]] && is_cidr "${N4_BASE}"; then
  base="${N4_BASE%%/*}"
  o1="${base%%.*}"; rem="${base#*.}"
  o2="${rem%%.*}"; rem="${rem#*.}"
  o3="${rem%%.*}"; o4="${rem#*.}"
  ip1="${o1}.$((10#${o2})).$((10#${o3})).$((10#${o4}+1))"
  ip2="${o1}.$((10#${o2})).$((10#${o3})).$((10#${o4}+2))"

  if [[ -f "${UPF}" ]]; then
    bak "${UPF}"
    # replace only IPv4 ranges (leave FEC0:: intact)
    sed -i -E 's|("range"[[:space:]]*:[[:space:]]*")([0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2})(")|\1'"${N4_BASE}"'\4|g' "${UPF}"
    sed -i -E 's|("exclude"[[:space:]]*:[[:space:]]*\[[[:space:]]*")[0-9.]+(/32)|\1'"${ip1}"'\2|' "${UPF}"
    grep -nE '"range"|exclude' "${UPF}" | sed 's/^/[remote] upf.n4 /'
  fi

  SMF="${NF_ROOT}/smf-1-values.yaml"
  if [[ -f "${SMF}" ]]; then
    bak "${SMF}"
    sed -i -E 's|("range"[[:space:]]*:[[:space:]]*")([0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2})(")|\1'"${N4_BASE}"'\4|g' "${SMF}"
    sed -i -E 's|("exclude"[[:space:]]*:[[:space:]]*\[[[:space:]]*")[0-9.]+(/32)|\1'"${ip2}"'\2|' "${SMF}"
    grep -nE '"range"|exclude' "${SMF}" | sed 's/^/[remote] smf.n4 /'
  fi
else
  echo "[remote] N4_BASE not provided/invalid — skipping N4 IPAM edits"
fi

echo "[remote] ✅ NF config complete on ${SERVER_IP}"
REMOTE
  rc=$?

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
