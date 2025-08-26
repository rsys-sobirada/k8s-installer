#!/usr/bin/env bash
set -euo pipefail

# --- required env (exported by Jenkins stage) ---
: "${SERVER_FILE:?missing}"          # path to server list
: "${SSH_KEY:?missing}"              # private key on Jenkins node
: "${NEW_VERSION:?missing}"          # e.g. 6.3.0_EA3 (we use only 6.3.0)
: "${NEW_BUILD_PATH:?missing}"       # e.g. /home/labadmin/6.3.0/EA3
: "${DEPLOYMENT_TYPE:?missing}"      # Low|Medium|High
HOST_USER="${HOST_USER:-root}"

echo "[cs_config] NEW_BUILD_PATH=${NEW_BUILD_PATH}"
echo "[cs_config] NEW_VERSION=${NEW_VERSION}"
echo "[cs_config] DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE}"

# Parse hosts (supports "name:ip:..." or just "ip/name")
mapfile -t HOSTS < <(awk '
  NF && $1 !~ /^#/ {
    if (index($0,":")>0) { n=split($0,a,":"); print a[2] } else { print $1 }
  }' "${SERVER_FILE}")

if ((${#HOSTS[@]}==0)); then
  echo "[cs_config] ERROR: no hosts parsed from ${SERVER_FILE}" >&2
  exit 1
fi

cs_update_and_install_on_host() {
  local host="$1"
  echo "[cs_config][$host] start"

  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "${SSH_KEY}" \
      "${HOST_USER}@${host}" bash -euo pipefail -s -- \
      "${NEW_VERSION}" "${NEW_BUILD_PATH}" "${DEPLOYMENT_TYPE}" <<'EOSSH'
set -euo pipefail
NEW_VERSION="$1"
BASE="$2"
DEPLOYMENT_TYPE="$3"

# Build CS_ROOT from BASE + version-only (strip tag after '_')
VER="${NEW_VERSION%%_*}"             # 6.3.0_EA3 -> 6.3.0 ; 6.3.0 -> 6.3.0
BASE="${BASE%/}"
CS_ROOT="${BASE}/TRILLIUM_5GCN_CNF_REL_${VER}/common-services/scripts"

echo "[remote:cs] BASE=${BASE}"
echo "[remote:cs] NEW_VERSION=${NEW_VERSION} (VER=${VER})"
echo "[remote:cs] CS_ROOT=${CS_ROOT}"

if [[ ! -d "${CS_ROOT}" ]]; then
  echo "[remote:cs] ERROR: CS_ROOT not found: ${CS_ROOT}" >&2
  exit 2
fi

# Locate global-values.yaml
YAML=""
for f in "${CS_ROOT}/global-values.yaml" "${CS_ROOT}/global-value.yaml"; do
  if [[ -f "$f" ]]; then YAML="$f"; break; fi
done
if [[ -z "$YAML" ]]; then
  echo "[remote:cs] ERROR: global-values.yaml not found under ${CS_ROOT}" >&2
  exit 2
fi
echo "[remote:cs] YAML=${YAML}"
cp -a "${YAML}" "${YAML}.bak"

# If DEPLOYMENT_TYPE is LOW, set capacitySetup: "LOW" (MEDIUM stays unchanged)
case "${DEPLOYMENT_TYPE}" in
  [Ll]ow)
    sed -i -E 's|^(\s*capacitySetup:\s*).*$|\1"LOW"|' "${YAML}"
    echo "[remote:cs] capacitySetup forced to LOW based on DEPLOYMENT_TYPE=LOW"
    ;;
  *)  echo "[remote:cs] capacitySetup left unchanged (DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE})" ;;
esac

# --- NEW: update cs-1-values.yaml: replace whole-word 'v1' with version-only (e.g., 6.3.0) ---
# Find the file (commonly near CS_ROOT). Search depth-limited to avoid surprises.
CSV_FILE="$(find -L "${CS_ROOT}" -maxdepth 3 -type f -name 'cs-1-values.yaml' | head -n1 || true)"
if [[ -z "${CSV_FILE}" ]]; then
  echo "[remote:cs] ERROR: cs-1-values.yaml not found under ${CS_ROOT}" >&2
  exit 2
fi
echo "[remote:cs] cs-1-values.yaml=${CSV_FILE}"
cp -a "${CSV_FILE}" "${CSV_FILE}.bak"

# Use GNU sed word boundary \b to replace v1 → VER (e.g., 6.3.0). Keep their style.
# Example they gave: sed -i 's/\\bv1\\b/'"6.3.0"'/g' *
# We apply it only to the target file to avoid unintended edits.
sed -i -E "s/\\bv1\\b/${VER}/g" "${CSV_FILE}"

echo "[remote:cs] Diff (global-values.yaml):"
diff -u "${YAML}.bak" "${YAML}" || true
echo "[remote:cs] Diff (cs-1-values.yaml):"
diff -u "${CSV_FILE}.bak" "${CSV_FILE}" || true

# Run the CS installer
cd "${CS_ROOT}"
if [[ -x ./install_cs.sh ]]; then
  echo "[remote:cs] Running ./install_cs.sh"
  ./install_cs.sh
else
  echo "[remote:cs] ERROR: install_cs.sh not executable or missing in ${CS_ROOT}" >&2
  exit 3
fi

echo "[remote:cs] CS install complete."
EOSSH

  echo "[cs_config][$host] done"
}

# iterate hosts with simple retry
for h in "${HOSTS[@]}"; do
  ok=0
  for attempt in 1 2 3; do
    if cs_update_and_install_on_host "$h"; then ok=1; break; fi
    echo "[cs_config][$h] attempt ${attempt} failed; retrying in 10s..."
    sleep 10
  done
  if ((ok==0)); then
    echo "[cs_config][$h] ERROR: failed after retries" >&2
    exit 1
  fi
done

echo "[cs_config] All hosts processed."
