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

# If DEPLOYMENT_TYPE is LOW, set capacitySetup: "LOW" (MEDIUM/other unchanged)
case "${DEPLOYMENT_TYPE}" in
  [Ll]ow)
    sed -i -E 's|^(\s*capacitySetup:\s*).*$|\1"LOW"|' "${YAML}"
    echo "[remote:cs] capacitySetup forced to LOW based on DEPLOYMENT_TYPE=LOW"
    ;;
  *)  echo "[remote:cs] capacitySetup left unchanged (DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE})" ;;
esac

# Update cs-1-values.yaml: replace whole-word 'v1' with version-only (e.g., 6.3.0)
CSV_FILE="$(find -L "${CS_ROOT}" -maxdepth 3 -type f -name 'cs-1-values.yaml' | head -n1 || true)"
if [[ -z "${CSV_FILE}" ]]; then
  echo "[remote:cs] ERROR: cs-1-values.yaml not found under ${CS_ROOT}" >&2
  exit 2
fi
echo "[remote:cs] cs-1-values.yaml=${CSV_FILE}"
cp -a "${CSV_FILE}" "${CSV_FILE}.bak"

# Use a word-boundary emulation in sed (portable to GNU sed) to replace only standalone 'v1'
# Replaces (^|non-word) v1 (non-word|$) with \1<VER>\2
sed -i -E "s/(^|[^[:alnum:]_])v1([^[:alnum:]_]|$)/\\1${VER}\\2/g" "${CSV_FILE}"

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

# ---- Post-install health check after 2 minutes ----
command -v kubectl >/dev/null 2>&1 || { echo "[remote:cs] ERROR: kubectl not found"; exit 3; }

pods_ok() {
  # Healthy if:
  # - STATUS Running and READY m/n with m==n
  # - Ignore Completed/Succeeded
  # - Ignore ipam pods that are Running and exactly 1/2
  # - Fail on obvious bad states
  kubectl get pods -A --no-headers 2>/dev/null | awk '
    {
      # 1=NS 2=NAME 3=READY 4=STATUS 5=RESTARTS 6=AGE
      split($3,a,"/"); m=a[1]; n=a[2];
      status=$4; name=$2;

      if (status ~ /(Completed|Succeeded)/) next;              # ignore finished jobs

      lname=tolower(name);
      if (lname ~ /ipam/ && status ~ /Running/ && m==1 && n==2) next;  # special-case ipam 1/2

      if (status ~ /Running/ && m!=n) exit 1;                  # running but not fully ready
      if (status ~ /(CrashLoopBackOff|ImagePullBackOff|ErrImagePull|BackOff|Error|Init:|Pending|Unknown|CreateContainerConfigError|Terminating)/)
        exit 1;
    }
    END { exit 0 }'
}

dump_bad() {
  echo "[remote:cs] --- Unhealthy pods (excluding ipam Running 1/2) ---"
  kubectl get pods -A --no-headers | awk '
    {
      split($3,a,"/"); m=a[1]; n=a[2];
      status=$4; ns=$1; name=$2;

      if (status ~ /(Completed|Succeeded)/) next;

      lname=tolower(name);
      if (lname ~ /ipam/ && status ~ /Running/ && m==1 && n==2) next;

      if ((status ~ /Running/ && m!=n) || status ~ /(CrashLoopBackOff|ImagePullBackOff|ErrImagePull|BackOff|Error|Init:|Pending|Unknown|CreateContainerConfigError|Terminating)/)
        printf "%-20s %-50s %-7s %-20s\n", ns, name, $3, status;
    }' || true
}

echo "[remote:cs] Waiting 120s before health check…"
sleep 120

if pods_ok; then
  echo "[remote:cs] ✅ Cluster healthy after CS install (pods Running/Ready)."
else
  echo "[remote:cs] ❌ Pods not healthy after CS install."
  dump_bad
  kubectl get pods -A || true
  exit 1
fi
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
