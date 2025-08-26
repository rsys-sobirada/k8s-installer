#!/usr/bin/env bash
set -euo pipefail

# --- required env (exported by Jenkins stage) ---
: "${SERVER_FILE:?missing}"          # host list (we support server_pci_map.txt format)
: "${SSH_KEY:?missing}"              # Jenkins node private key path
: "${NEW_VERSION:?missing}"          # e.g. 6.3.0_EA3 (we use only 6.3.0)
: "${NEW_BUILD_PATH:?missing}"       # e.g. /home/labadmin/6.3.0/EA3
: "${DEPLOYMENT_TYPE:?missing}"      # Low|Medium|High

# Optional overrides (beat map file values if provided)
#   CN_DEPLOYMENT=VM|SRIOV
#   N3_PCI=0000:08:00.0
#   N6_PCI=0000:08:01.1
SERVER_PCI_MAP="${SERVER_PCI_MAP:-${SERVER_FILE}}"
SERVER_IP_RANGE_MAP="${SERVER_IP_RANGE_MAP:-${SERVER_FILE}}"
HOST_USER="${HOST_USER:-root}"

# capacity from DEPLOYMENT_TYPE
case "${DEPLOYMENT_TYPE}" in
  [Ll]ow)    cap="LOW" ;;
  [Mm]edium) cap="MEDIUM" ;;
  [Hh]igh)   cap="HIGH" ;;
  *)         cap="MEDIUM" ;;
esac

echo "[nf_config] NEW_BUILD_PATH=${NEW_BUILD_PATH}"
echo "[nf_config] NEW_VERSION=${NEW_VERSION}"
echo "[nf_config] DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE} (${cap})"
echo "[nf_config] SERVER_FILE=${SERVER_FILE}"
echo "[nf_config] SERVER_PCI_MAP=${SERVER_PCI_MAP}"
echo "[nf_config] SERVER_IP_RANGE_MAP=${SERVER_IP_RANGE_MAP}"

# ----- read target host IPs from SERVER_FILE -----
# supports:
#   name:IP:path:VM|SRIOV:PCI:PCI:...  (we take 2nd field)
#   IP                                 (takes the line)
mapfile -t HOSTS < <(awk '
  NF && $1 !~ /^#/ {
    if (index($0,":")>0) { n=split($0,a,":"); print a[2] }
    else                 { print $1 }
  }' "${SERVER_FILE}")

if ((${#HOSTS[@]}==0)); then
  echo "[nf_config] ERROR: no hosts parsed from ${SERVER_FILE}" >&2
  exit 1
fi

configure_on_host() {
  local host="$1"
  echo "[nf_config][$host] start"

  # ship maps to remote (best effort)
  [[ -f "${SERVER_PCI_MAP}" ]] && scp -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${SERVER_PCI_MAP}"      "${HOST_USER}@${host}:/tmp/server_pci_map.txt" || true
  [[ -f "${SERVER_IP_RANGE_MAP}" ]] && scp -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${SERVER_IP_RANGE_MAP}" "${HOST_USER}@${host}:/tmp/server_map.txt"     || true

  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "${SSH_KEY}" \
      "${HOST_USER}@${host}" bash -euo pipefail -s -- \
      "${NEW_VERSION}" "${NEW_BUILD_PATH}" "${host}" "${cap}" "${CN_DEPLOYMENT:-}" "${N3_PCI:-}" "${N6_PCI:-}" <<'EOSSH'
set -euo pipefail
NEW_VERSION="$1"
BASE="$2"
TARGET_IP="$3"
CAP="$4"
CN_DEPLOYMENT_IN="$5"
N3_PCI_IN="${6:-}"
N6_PCI_IN="${7:-}"

# ---- derive paths ----
VER="${NEW_VERSION%%_*}"                 # 6.3.0_EA3 -> 6.3.0
BASE="${BASE%/}"
NF_ROOT="${BASE}/TRILLIUM_5GCN_CNF_REL_${VER}/nf-services/scripts"
echo "[remote:nf] NF_ROOT=${NF_ROOT}"
[[ -d "${NF_ROOT}" ]] || { echo "[remote:nf] ERROR: NF_ROOT not found"; exit 2; }

# ---- parse server_pci_map.txt for this IP (mode + PCI + optional build path + optional N4 base) ----
CN_DEPLOYMENT="${CN_DEPLOYMENT_IN}"
N3_PCI="${N3_PCI_IN}"
N6_PCI="${N6_PCI_IN}"

if [[ -z "${CN_DEPLOYMENT}" || -z "${N3_PCI}" || -z "${N6_PCI}" ]]; then
  if [[ -f /tmp/server_pci_map.txt ]]; then
    # match line containing :<IP>:
    map_line="$(grep -E "^[[:space:]]*[^#]*:[[:space:]]*${TARGET_IP}[[:space:]]*:" /tmp/server_pci_map.txt | head -n1 || true)"
    if [[ -n "${map_line}" ]]; then
      # Field 3 = old build path, field 4 = mode (safe: PCI fields come later)
      OLD_BUILD_PATH="$(printf '%s\n' "${map_line}" | awk -F: '{print $3}')"
      CN_DEPLOYMENT="$(printf '%s\n' "${map_line}" | awk -F: '{print toupper($4)}')"

      # Extract first two valid PCI tokens anywhere on the line
      readarray -t _pcis < <(printf '%s\n' "${map_line}" | grep -Eo '[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]')
      N3_PCI="${N3_PCI:-${_pcis[0]:-}}"
      N6_PCI="${N6_PCI:-${_pcis[1]:-}}"
      if [[ -n "${OLD_BUILD_PATH:-}" && "${OLD_BUILD_PATH%/}" != "${BASE}" ]]; then
        echo "[remote:nf] WARNING: OLD_BUILD_PATH in map (${OLD_BUILD_PATH}) != NEW_BUILD_PATH (${BASE})"
      fi
    fi
  fi
fi
[[ -n "${CN_DEPLOYMENT:-}" ]] && CN_DEPLOYMENT="$(echo "${CN_DEPLOYMENT}" | tr '[:lower:]' '[:upper:]')"
echo "[remote:nf] CN_DEPLOYMENT=${CN_DEPLOYMENT:-unknown}  N3_PCI=${N3_PCI:-unset}  N6_PCI=${N6_PCI:-unset}"

# ---- read N4 base (prefer /tmp/server_map.txt, else fallback to server_pci_map.txt) ----
N4_BASE_CIDR=""
if [[ -f /tmp/server_map.txt ]]; then
  map_line2="$(grep -E "^[[:space:]]*[^#]*:[[:space:]]*${TARGET_IP}[[:space:]]*:" /tmp/server_map.txt | head -n1 || true)"
  [[ -n "${map_line2}" ]] && N4_BASE_CIDR="$(printf '%s\n' "${map_line2}" | grep -Eo '([0-9]{1,3}\.){3}0(/[0-9]{1,2})?' | head -n1 || true)"
fi
if [[ -z "${N4_BASE_CIDR}" && -f /tmp/server_pci_map.txt ]]; then
  map_line3="$(grep -E "^[[:space:]]*[^#]*:[[:space:]]*${TARGET_IP}[[:space:]]*:" /tmp/server_pci_map.txt | head -n1 || true)"
  [[ -n "${map_line3}" ]] && N4_BASE_CIDR="$(printf '%s\n' "${map_line3}" | grep -Eo '([0-9]{1,3}\.){3}0(/[0-9]{1,2})?' | head -n1 || true)"
fi

if [[ -z "${N4_BASE_CIDR}" ]]; then
  echo "[remote:nf] WARNING: No N4 base found for ${TARGET_IP}; skipping SMF/UPF N4 ipam edits"
fi

# normalize N4 base; default mask /30 if missing
N4_MASK="30"
if [[ -n "${N4_BASE_CIDR}" ]]; then
  if [[ "${N4_BASE_CIDR}" == */* ]]; then
    N4_MASK="${N4_BASE_CIDR##*/}"
    N4_BASE="${N4_BASE_CIDR%/*}"
  else
    N4_BASE="${N4_BASE_CIDR}"
  fi
  IFS='.' read -r a b c d <<<"${N4_BASE}"
  N4_BASE="${a}.${b}.${c}.0"
  N4_RANGE="${N4_BASE}/${N4_MASK}"
  SMF_EXCL="${a}.${b}.${c}.2/32"
  UPF_EXCL="${a}.${b}.${c}.1/32"
  echo "[remote:nf] N4_RANGE=${N4_RANGE}  (SMF exclude ${SMF_EXCL} / UPF exclude ${UPF_EXCL})"
fi

# ---- locate global-values.yaml under NF_ROOT ----
NF_YAML=""
for f in "${NF_ROOT}/global-values.yaml" "${NF_ROOT}/global-value.yaml"; do
  [[ -f "$f" ]] && { NF_YAML="$f"; break; }
done
[[ -n "${NF_YAML}" ]] || { echo "[remote:nf] ERROR: global-values.yaml not found"; exit 2; }
cp -a "${NF_YAML}" "${NF_YAML}.bak"

# 1) capacitySetup based on DEPLOYMENT_TYPE
sed -i -E "s|^(\s*capacitySetup:\s*).*$|\1\"${CAP}\"|" "${NF_YAML}"

# 2) ingressExtFQDN: <server-ip>.nip.io
sed -i -E "s|^(\s*ingressExtFQDN:\s*).*$|\1${TARGET_IP}.nip.io|" "${NF_YAML}"

# 3) k8sCpuMgrStaticPolicyEnable: false for LOW
if [[ "${CAP}" == "LOW" ]]; then
  sed -i -E "s|^(\s*k8sCpuMgrStaticPolicyEnable:\s*).*$|\1false|" "${NF_YAML}"
fi

echo "[remote:nf] Diff (global-values.yaml):"
diff -u "${NF_YAML}.bak" "${NF_YAML}" || true

# 4) whole-word v1 -> VER in all YAMLs under NF_ROOT
while IFS= read -r -d '' y; do
  cp -a "$y" "$y.bak" || true
  sed -i -E "s/(^|[^[:alnum:]_])v1([^[:alnum:]_]|$)/\\1${VER}\\2/g" "$y"
  diff -u "$y.bak" "$y" || true
done < <(find -L "${NF_ROOT}" -maxdepth 3 -type f -name '*.yaml' -print0)

# 5) amf externalIP: <server-ip>
AMF_FILE="$(find -L "${NF_ROOT}" -maxdepth 3 -type f -name 'amf-1-values.yaml' | head -n1 || true)"
if [[ -n "${AMF_FILE}" ]]; then
  cp -a "${AMF_FILE}" "${AMF_FILE}.bak"
  sed -i -E "s|^(\s*externalIP:\s*).*$|\1${TARGET_IP}|" "${AMF_FILE}"
  echo "[remote:nf] Diff (amf-1-values.yaml):"
  diff -u "${AMF_FILE}.bak" "${AMF_FILE}" || true
else
  echo "[remote:nf] WARNING: amf-1-values.yaml not found (skipping externalIP)"
fi

# helper to replace first "range": "<cidr>" and first IPv4 /32 inside exclude array
replace_ipam_range_and_exclude() {
  local file="$1" new_range="$2" new_excl="$3"
  [[ -n "${new_range}" && -n "${new_excl}" ]] || return 0
  awk -v rng="${new_range}" -v ex="${new_excl}" '
    function is_ipv4range(){ return ($0 ~ /"range":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/) }
    BEGIN{ inEx=0; doneR=0; doneE=0 }
    {
      if ($0 ~ /^[[:space:]]*"?exclude"?:[[:space:]]*\[/) inEx=1
      if (inEx && $0 ~ /\]/) inEx=0
      if (!doneR && is_ipv4range()) { sub(/"range":[[:space:]]*"[^"]+"/, "\"range\": \"" rng "\""); doneR=1; print; next }
      if (inEx && !doneE && $0 ~ /"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/32"/) { sub(/"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/32"/, "\"" ex "\""); doneE=1; print; next }
      print
    }' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
}

# 6) SMF N4 ipam edits
if [[ -n "${N4_RANGE:-}" ]]; then
  SMF_FILE="$(find -L "${NF_ROOT}" -maxdepth 3 -type f -name 'smf-1-values.yaml' | head -n1 || true)"
  if [[ -n "${SMF_FILE}" ]]; then
    cp -a "${SMF_FILE}" "${SMF_FILE}.bak"
    replace_ipam_range_and_exclude "${SMF_FILE}" "${N4_RANGE}" "${SMF_EXCL}"
    echo "[remote:nf] Diff (smf-1-values.yaml):"
    diff -u "${SMF_FILE}.bak" "${SMF_FILE}" || true
  else
    echo "[remote:nf] WARNING: smf-1-values.yaml not found; skipping SMF N4 ipam"
  fi
fi

# 7) UPF N4 ipam edits (under upfsp.n4.ipam)
if [[ -n "${N4_RANGE:-}" ]]; then
  UPF_FILE="$(find -L "${NF_ROOT}" -maxdepth 3 -type f -name 'upf-1-values.yaml' | head -n1 || true)"
  if [[ -n "${UPF_FILE}" ]]; then
    cp -a "${UPF_FILE}" "${UPF_FILE}.bak"
    replace_ipam_range_and_exclude "${UPF_FILE}" "${N4_RANGE}" "${UPF_EXCL}"
    echo "[remote:nf] Diff (upf-1-values.yaml N4 ipam):"
    diff -u "${UPF_FILE}.bak" "${UPF_FILE}" || true
  else
    echo "[remote:nf] WARNING: upf-1-values.yaml not found; skipping UPF N4 ipam"
  fi
fi

# 8) UPF VM-based tweaks (devPassthrough + PCI wiring)
if [[ "${CN_DEPLOYMENT:-}" == "VM" || "${CN_DEPLOYMENT:-}" == "VM-BASED" || "${CN_DEPLOYMENT:-}" == "VMB" ]]; then
  UPF_FILE="$(find -L "${NF_ROOT}" -maxdepth 3 -type f -name 'upf-1-values.yaml' | head -n1 || true)"
  if [[ -z "${UPF_FILE}" ]]; then
    echo "[remote:nf] WARNING: upf-1-values.yaml not found; skipping UPF PCI edits"
  else
    if [[ -z "${N3_PCI}" || -z "${N6_PCI}" ]]; then
      echo "[remote:nf] ERROR: VM-based CN but N3_PCI or N6_PCI missing (from map or env)"; exit 3
    fi
    cp -a "${UPF_FILE}" "${UPF_FILE}.bak.pci" || true
    awk -v n3="${N3_PCI}" -v n6="${N6_PCI}" '
      function indent(s){ match(s,/^[ \t]*/); return RLENGTH }
      BEGIN{ in_ic=0; ic_indent=0; sec="" }
      {
        if (!in_ic && $0 ~ /^[[:space:]]*intfConfig:[[:space:]]*$/) { in_ic=1; ic_indent=indent($0); print; next }
        if (in_ic) {
          if (indent($0) <= ic_indent && $0 !~ /^[[:space:]]*$/) { in_ic=0; sec="" }
          else {
            if ($0 ~ /^[[:space:]]*type:[[:space:]]*/) { match($0,/^[[:space:]]*/); ind=substr($0,1,RLENGTH); $0=ind "type: \"devPassthrough\""; print; next }
            if ($0 ~ /^[[:space:]]*nguInterface:[[:space:]]*$/) { sec="ngu"; print; next }
            if ($0 ~ /^[[:space:]]*n6Interface_0:[[:space:]]*$/) { sec="n6_0"; print; next }
            if ($0 ~ /^[[:space:]]*[A-Za-z0-9_]+:[[:space:]]*$/ && indent($0) <= ic_indent+2) { sec="" }
            if (sec=="ngu") {
              if ($0 ~ /^[[:space:]]*pciDeviceName:/) { match($0,/^[[:space:]]*/); ind=substr($0,1,RLENGTH); $0=ind "pciDeviceName: PCIDEVICE_INTEL_COM_SRIOV_NETDEVICE_NGU_UPF"; print; next }
              if ($0 ~ /^[[:space:]]*pciAddress:/)    { match($0,/^[[:space:]]*/); ind=substr($0,1,RLENGTH); $0=ind "pciAddress: " n3; print; next }
            } else if (sec=="n6_0") {
              if ($0 ~ /^[[:space:]]*pciDeviceName:/) { match($0,/^[[:space:]]*/); ind=substr($0,1,RLENGTH); $0=ind "pciDeviceName: PCIDEVICE_INTEL_COM_SRIOV_NETDEVICE_N6_UPF"; print; next }
              if ($0 ~ /^[[:space:]]*pciAddress:/)    { match($0,/^[[:space:]]*/); ind=substr($0,1,RLENGTH); $0=ind "pciAddress: " n6; print; next }
            }
            print; next
          }
        }
        print
      }
    ' "${UPF_FILE}" > "${UPF_FILE}.tmp" && mv "${UPF_FILE}.tmp" "${UPF_FILE}"
    echo "[remote:nf] Diff (upf-1-values.yaml PCI edits):"
    diff -u "${UPF_FILE}.bak.pci" "${UPF_FILE}" || true
  fi
else
  echo "[remote:nf] CN deployment not VM-based; skipping UPF PCI edits"
fi

echo "[remote:nf] NF services config updates complete."
EOSSH

  echo "[nf_config][$host] done"
}

# iterate hosts (3 attempts per host)
for h in "${HOSTS[@]}"; do
  ok=0
  for attempt in 1 2 3; do
    if configure_on_host "$h"; then ok=1; break; fi
    echo "[nf_config][$h] attempt ${attempt} failed; retrying in 10s..."
    sleep 10
  done
  if ((ok==0)); then
    echo "[nf_config][$h] ERROR: failed after retries" >&2
    exit 1
  fi
done

echo "[nf_config] All hosts processed."
