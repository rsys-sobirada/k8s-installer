#!/usr/bin/env bash
set -euo pipefail

# --- required env (exported by Jenkins stage) ---
: "${SERVER_FILE:?missing}"          # path to server list
: "${SSH_KEY:?missing}"              # private key on Jenkins node
: "${NEW_VERSION:?missing}"          # e.g. 6.3.0_EA3 (we use only 6.3.0)
: "${NEW_BUILD_PATH:?missing}"       # e.g. /home/labadmin/6.3.0/EA3
: "${DEPLOYMENT_TYPE:?missing}"      # Low|Medium|High
HOST_USER="${HOST_USER:-root}"

# capacity from DEPLOYMENT_TYPE
case "${DEPLOYMENT_TYPE}" in
  [Ll]ow)    cap="LOW" ;;
  [Mm]edium) cap="MEDIUM" ;;
  [Hh]igh)   cap="HIGH" ;;
  *)         cap="MEDIUM" ;;
esac

echo "[ps_config] NEW_BUILD_PATH=${NEW_BUILD_PATH}"
echo "[ps_config] NEW_VERSION=${NEW_VERSION}"
echo "[ps_config] DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE} (${cap})"

# Parse hosts (supports "name:ip:..." or just "ip/name")
mapfile -t HOSTS < <(awk '
  NF && $1 !~ /^#/ {
    if (index($0,":")>0) { n=split($0,a,":"); print a[2] } else { print $1 }
  }' "${SERVER_FILE}")

if ((${#HOSTS[@]}==0)); then
  echo "[ps_config] ERROR: no hosts parsed from ${SERVER_FILE}" >&2
  exit 1
fi

ps_update_and_install_on_host() {
  local host="$1"           # expected to be an IP from SERVER_FILE
  echo "[ps_config][$host] start"

  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "${SSH_KEY}" \
      "${HOST_USER}@${host}" bash -euo pipefail -s -- \
      "${NEW_VERSION}" "${NEW_BUILD_PATH}" "${host}" "${cap}" <<'EOSSH'
set -euo pipefail
NEW_VERSION="$1"
BASE="$2"
TARGET_IP="$3"     # <-- use the server IP from SERVER_FILE
CAP="$4"

# --- Build PS_ROOT from BASE + version-only (strip tag after '_') ---
VER="${NEW_VERSION%%_*}"             # 6.3.0_EA3 -> 6.3.0 ; 6.3.0 -> 6.3.0
BASE="${BASE%/}"
PS_ROOT="${BASE}/TRILLIUM_5GCN_CNF_REL_${VER}/platform-services/scripts"

echo "[remote] BASE=${BASE}"
echo "[remote] NEW_VERSION=${NEW_VERSION} (VER=${VER})"
echo "[remote] TARGET_IP=${TARGET_IP}"
echo "[remote] PS_ROOT=${PS_ROOT}"

if [[ ! -d "${PS_ROOT}" ]]; then
  echo "[remote] ERROR: PS_ROOT not found: ${PS_ROOT}" >&2
  exit 2
fi

# Helpers
has_image_pull_backoff() {
  kubectl get pods -A --no-headers 2>/dev/null | grep -q "ImagePullBackOff"
}
show_backoff_pods() {
  echo "[remote] Pods in ImagePullBackOff:"
  kubectl get pods -A --no-headers | awk '$4 ~ /ImagePullBackOff/ {printf "%-20s %-50s %-7s %-20s\n",$1,$2,$3,$4}'
}

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

# update global.registry: docker.io -> rsys-dockerproxy.radisys.com (inside `global:` block)
awk -v reg="rsys-dockerproxy.radisys.com" '
  BEGIN{ in_g=0 }
  {
    if ($0 ~ /^[[:space:]]*global:[[:space:]]*$/) { in_g=1; print; next }
    if (in_g && $0 ~ /^[^[:space:]]/) { in_g=0 }
    if (in_g && $0 ~ /^[[:space:]]*registry:[[:space:]]*/) {
      match($0, /^[[:space:]]*/); indent=substr($0,1,RLENGTH);
      print indent "registry: " reg; next
    }
    print
  }
' "${YAML}" > "${YAML}.tmp" && mv "${YAML}.tmp" "${YAML}"

# update metallb.L2Pool first list entry to "<server IP>/32"
awk -v ip="${TARGET_IP}" '
  BEGIN{ in_m=0; in_l=0; replaced=0 }
  {
    if ($0 ~ /^[[:space:]]*metallb:[[:space:]]*$/) { in_m=1; in_l=0 }
    else if (in_m && $0 ~ /^[[:space:]]*L2Pool:[[:space:]]*$/) { in_l=1 }
    else if (in_m && in_l && $0 ~ /^[[:space:]]*-[[:space:]]*"/ && replaced==0) {
      sub(/"[0-9.]+\/32"/, "\"" ip "/32\""); replaced=1
    } else if (in_m && $0 ~ /^[[:space:]]*[A-Za-z0-9_]+:/ && $0 !~ /^[[:space:]]*L2Pool:/) {
      in_m=0; in_l=0
    }
    print
  }
' "${YAML}" > "${YAML}.tmp" && mv "${YAML}.tmp" "${YAML}"

echo "[remote] Diff:"
diff -u "${YAML}.bak" "${YAML}" || true

# ---- Run installer ----
cd "${PS_ROOT}"
if [[ -x ./install_ps.sh ]]; then
  echo "[remote] Running ./install_ps.sh"
  ./install_ps.sh
else
  echo "[remote] ERROR: install_ps.sh not executable or missing in ${PS_ROOT}" >&2
  exit 3
fi

# ---- Post-install ImagePullBackOff handling ----
echo "[remote] Waiting 60s before health check…"
sleep 60
if has_image_pull_backoff; then
  echo "[remote] Detected ImagePullBackOff after install. Showing pods:"
  show_backoff_pods
  echo "[remote] Waiting 10 minutes to allow images to pull…"
  sleep 600

  if has_image_pull_backoff; then
    echo "[remote] Still ImagePullBackOff after additional 10 minutes — attempting uninstall/reinstall"
    [[ -x ./uninstall_ps.sh ]] || { echo "[remote] ERROR: uninstall_ps.sh missing or not executable"; exit 4; }
    ./uninstall_ps.sh

    echo "[remote] Re-running install_ps.sh"
    ./install_ps.sh

    echo "[remote] Waiting 60s before re-check…"
    sleep 60
    if has_image_pull_backoff; then
      echo "[remote] Backoff persists after reinstall; waiting 10 minutes one more time…"
      sleep 600
      if has_image_pull_backoff; then
        echo "[remote] ❌ ImagePullBackOff still present after reinstall + wait. Aborting."
        show_backoff_pods
        exit 5
      fi
    fi
  fi
fi
echo "[remote] ✅ No ImagePullBackOff detected (final)."

# ---- Copy & run load.sh (using NEW_BUILD_PATH + version-only) ----
LOAD_SRC="${BASE}/TRILLIUM_5GCN_CNF_REL_${VER}/common/tools/install/load.sh"
LOAD_DST="${BASE}/load.sh"

if [[ ! -f "${LOAD_SRC}" ]]; then
  echo "[remote] ERROR: load.sh not found at ${LOAD_SRC}" >&2
  exit 6
fi

echo "[remote] Copying load.sh: ${LOAD_SRC} -> ${LOAD_DST}"
cp -f "${LOAD_SRC}" "${LOAD_DST}"
chmod +x "${LOAD_DST}"

echo "[remote] Running ${LOAD_DST} ${VER}"
( cd "${BASE}" && "${LOAD_DST}" "${VER}" )

echo "[remote] load.sh completed."
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
