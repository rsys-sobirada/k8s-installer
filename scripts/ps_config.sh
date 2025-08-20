#!/usr/bin/env bash
set -euo pipefail

# --- required env (exported by Jenkins stage) ---
: "${SERVER_FILE:?missing}"
: "${SSH_KEY:?missing}"
: "${NEW_VERSION:?missing}"           # e.g. 6.3.0_EA2 or 6.3.0
: "${NEW_BUILD_PATH:?missing}"        # e.g. /home/labadmin
: "${INSTALL_IP_ADDR:?missing}"       # e.g. 10.10.10.20/24
: "${DEPLOYMENT_TYPE:?missing}"       # Low|Medium|High

ip_only="${INSTALL_IP_ADDR%%/*}"

# map capacity from DEPLOYMENT_TYPE
case "${DEPLOYMENT_TYPE}" in
  [Ll]ow)    cap="LOW" ;;
  [Mm]edium) cap="MEDIUM" ;;
  [Hh]igh)   cap="HIGH" ;;
  *)         cap="MEDIUM" ;;
esac

echo "[ps_config] Using TARGET_IP=${ip_only}, capacitySetup=${cap}"

# Parse hosts from SERVER_FILE (supports "name:ip:..." or just "ip/name")
mapfile -t HOSTS < <(awk '
  NF && $1 !~ /^#/ {
    if (index($0,":")>0) { n=split($0,a,":"); print a[2] } else { print $1 }
  }' "${SERVER_FILE}")

if ((${#HOSTS[@]}==0)); then
  echo "[ps_config] ERROR: no hosts parsed from ${SERVER_FILE}" >&2
  exit 1
fi

ps_update_and_install_on_host() {
  local host="$1"
  echo "[ps_config][$host] start"

  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" bash -euo pipefail -s -- "${NEW_VERSION}" "${NEW_BUILD_PATH}" "${ip_only}" "${cap}" <<'EOSSH'
set -euo pipefail
NEW_VERSION="$1"
BASE="$2"
TARGET_IP="$3"
CAP="$4"

# derive PS scripts dir from NEW_VERSION + BASE
if [[ "$NEW_VERSION" == *_* ]]; then
  VER="${NEW_VERSION%%_*}"
  TAG="${NEW_VERSION#*_}"
  PS_ROOT="${BASE%/}/${VER}/${TAG}/TRILLIUM_5GCN_CNF_REL_${VER}/platform-services/scripts"
else
  VER="$NEW_VERSION"
  PS_ROOT="${BASE%/}/${VER}/TRILLIUM_5GCN_CNF_REL_${VER}/platform-services/scripts"
fi

echo "[remote] PS_ROOT=${PS_ROOT}"

# find the yaml (support two common names)
YAML=""
for f in "${PS_ROOT}/global-values.yaml" "${PS_ROOT}/global-value.yaml"; do
  if [[ -f "$f" ]]; then YAML="$f"; break; fi
done
if [[ -z "$YAML" ]]; then
  echo "[remote] ERROR: global-values.yaml not found under ${PS_ROOT}" >&2
  exit 2
fi
echo "[remote] YAML=${YAML}"

cp -a "${YAML}" "${YAML}.bak"

# update scalars (preserve indentation)
sed -i -E "s|^(\s*elasticHost:\s*).*$|\1${TARGET_IP}|"            "${YAML}"
sed -i -E "s|^(\s*capacitySetup:\s*).*$|\1\"${CAP}\"|"           "${YAML}"
sed -i -E "s|^(\s*ingressExtFQDN:\s*).*$|\1${TARGET_IP}.nip.io|" "${YAML}"

# update metallb.L2Pool first list entry to "<IP>/32"
awk -v ip="${TARGET_IP}" '
  BEGIN{ in_m=0; in_l=0; replaced=0 }
  {
    if ($0 ~ /^[[:space:]]*metallb:[[:space:]]*$/) { in_m=1; in_l=0 }
    else if (in_m && $0 ~ /^[[:space:]]*L2Pool:[[:space:]]*$/) { in_l=1 }
    else if (in_m && in_l && $0 ~ /^[[:space:]]*-[[:space:]]*"/ && replaced==0) {
      sub(/"[0-9.]+\/32"/, "\"" ip "/32\"")
      replaced=1
    } else if (in_m && $0 ~ /^[[:space:]]*[A-Za-z0-9_]+:/ && $0 !~ /^[[:space:]]*L2Pool:/) {
      in_m=0; in_l=0
    }
    print
  }
' "${YAML}" > "${YAML}.tmp" && mv "${YAML}.tmp" "${YAML}"

echo "[remote] Diff:"
diff -u "${YAML}.bak" "${YAML}" || true

# run the installer
cd "${PS_ROOT}"
if [[ -x ./install_ps.sh ]]; then
  echo "[remote] Running ./install_ps.sh"
  ./install_ps.sh
else
  echo "[remote] ERROR: install_ps.sh not executable or missing in ${PS_ROOT}" >&2
  exit 3
fi

echo "[remote] PS install complete."
EOSSH

  echo "[ps_config][$host] done"
}

# iterate hosts with simple retry
for h in "${HOSTS[@]}"; do
  ok=0
  for attempt in 1 2 3; do
    if ps_update_and_install_on_host "$h"; then ok=1; break; fi
    echo "[ps_config][$h] attempt ${attempt} failed; retrying in 10s..."
    sleep 10
  done
  if ((ok==0)); then
    echo "[ps_config][$h] ERROR: failed after retries" >&2
    exit 1
  fi
done

echo "[ps_config] All hosts processed."
