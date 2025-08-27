#!/usr/bin/env bash
set -euo pipefail

# --- required env (exported by Jenkins stage) ---
: "${SERVER_FILE:?missing}"          # path to server list
: "${SSH_KEY:?missing}"              # private key on Jenkins node
: "${NEW_VERSION:?missing}"          # e.g. 6.3.0_EA3 (we use only 6.3.0)
: "${NEW_BUILD_PATH:?missing}"       # e.g. /home/labadmin/6.3.0/EA3
: "${DEPLOYMENT_TYPE:?missing}"      # Low|Medium|High
HOST_USER="${HOST_USER:-root}"

# Map DEPLOYMENT_TYPE → capacity
case "${DEPLOYMENT_TYPE}" in
  [Ll]ow)    cap="LOW" ;;
  [Mm]edium) cap="MEDIUM" ;;
  [Hh]igh)   cap="HIGH" ;;
  *)         cap="MEDIUM" ;;
esac

echo "[ps_config] NEW_BUILD_PATH=${NEW_BUILD_PATH}"
echo "[ps_config] NEW_VERSION=${NEW_VERSION}"
echo "[ps_config] DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE} (${cap})"

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

  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "${SSH_KEY}" \
      "${HOST_USER}@${host}" bash -euo pipefail -s -- \
      "${NEW_VERSION}" "${NEW_BUILD_PATH}" "${host}" "${cap}" <<'EOSSH'
set -euo pipefail
NEW_VERSION="$1"
BASE="$2"
TARGET_IP="$3"     # server IP from SERVER_FILE
CAP="$4"

# Derive version-only and paths
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

# ---- helpers ----
command -v # Parse hosts (format: name:ip:build_path:VM|SRIOV:N3:N6:N4_CIDR:AMF_N2_IP)
mapfile -t HOSTS < <(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){ split($0,a,":"); print a[2] } else { print $1 } }' "${SERVER_FILE}")
if ((${#HOSTS[@]}==0)); then
  echo "[ps_config] ERROR: no hosts parsed from ${SERVER_FILE}" >&2
  exit 2
fi
RUNNER="${HOSTS[0]}"

kubectl >/dev/null 2>&1 || { echo "[remote] ERROR: kubectl not found"; exit 3; }

has_image_pull_backoff() {
  kubectl get pods -A --no-headers 2>/dev/null | grep -q "ImagePullBackOff"
}

show_backoff_pods() {
  echo "[remote] Pods in ImagePullBackOff:"
  kubectl get pods -A --no-headers | awk '$4 ~ /ImagePullBackOff/ {printf "%-20s %-50s %-7s %-20s\n",$1,$2,$3,$4}'
}

mongo_pods_ok() {
  # All pods in namespace "mongodb" must be Running and m==n
  kubectl get pods -n mongodb --no-headers 2>/dev/null | awk '
    {
      # Columns with -n: 1=NAME 2=READY 3=STATUS 4=RESTARTS 5=AGE
      split($2,a,"/"); m=a[1]; n=a[2]; status=$3;
      if (status !~ /Running/ || m!=n) exit 1
    }
    END { exit 0 }'
}

dump_mongo_pods() {
  echo "[remote] --- MongoDB pods ---"
  kubectl get pods -n mongodb -o wide || true
}

# ---- locate YAML and update ----
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

# elasticHost: <server IP>
sed -i -E "s|^(\s*elasticHost:\s*).*$|\1${TARGET_IP}|"            "${YAML}"
# capacitySetup: "LOW|MEDIUM|HIGH"
sed -i -E "s|^(\s*capacitySetup:\s*).*$|\1\"${CAP}\"|"           "${YAML}"
# ingressExtFQDN: <server IP>.nip.io
sed -i -E "s|^(\s*ingressExtFQDN:\s*).*$|\1${TARGET_IP}.nip.io|" "${YAML}"

# global.registry: docker.io -> rsys-dockerproxy.radisys.com (inside `global:` block only)
awk -v reg="rsys-dockerproxy.radisys.com" '
  BEGIN{ in_g=0 }
  {
    if ($0 ~ /^[[:space:]]*global:[[:space:]]*$/) { in_g=1; print; next }
    if (in_g && $0 ~ /^[^[:space:]]/) { in_g=0 }   # left the global block
    if (in_g && $0 ~ /^[[:space:]]*registry:[[:space:]]*/) {
      match($0, /^[[:space:]]*/); indent=substr($0,1,RLENGTH);
      print indent "registry: " reg; next
    }
    print
  }
' "${YAML}" > "${YAML}.tmp" && mv "${YAML}.tmp" "${YAML}"

# metallb.L2Pool first entry -> "<IP>/32"
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

echo "[remote] Diff (PS global-values.yaml):"
diff -u "${YAML}.bak" "${YAML}" || true

# ---- Run PS installer ----
cd "${PS_ROOT}"
if [[ -x ./install_ps.sh ]]; then
  echo "[remote] Running ./install_ps.sh"
  ./install_ps.sh
else
  echo "[remote] ERROR: install_ps.sh not executable or missing in ${PS_ROOT}" >&2
  exit 3
fi

# ---- Post-PS ImagePullBackOff handling ----
echo "[remote] Waiting 60s before PS health check…"
sleep 60
if has_image_pull_backoff; then
  echo "[remote] Detected ImagePullBackOff after PS install. Showing pods:"
  show_backoff_pods
  echo "[remote] Waiting 10 minutes to allow images to pull…"
  sleep 600

  if has_image_pull_backoff; then
    echo "[remote] Still ImagePullBackOff after additional 10 minutes — attempting PS uninstall/reinstall"
    [[ -x ./uninstall_ps.sh ]] || { echo "[remote] ERROR: uninstall_ps.sh missing or not executable"; exit 4; }
    ./uninstall_ps.sh

    echo "[remote] Re-running install_ps.sh"
    ./install_ps.sh

    echo "[remote] Waiting 60s before PS re-check…"
    sleep 60
    if has_image_pull_backoff; then
      echo "[remote] Backoff persists after PS reinstall; waiting 10 minutes one more time…"
      sleep 600
      if has_image_pull_backoff; then
        echo "[remote] ❌ ImagePullBackOff still present after PS reinstall + wait. Aborting."
        show_backoff_pods
        exit 5
      fi
    end
  fi
fi
echo "[remote] ✅ No ImagePullBackOff detected for PS (final)."

# ---- MongoDB install & checks (with post-reinstall 100s delay) ----
if [[ -x ./install_mongodb.sh ]]; then
  echo "[remote] Installing MongoDB…"
  ./install_mongodb.sh
else
  echo "[remote] ERROR: install_mongodb.sh not found or not executable in ${PS_ROOT}" >&2
  exit 6
fi

echo "[remote] Waiting 100s for MongoDB pods…"
sleep 100

if ! mongo_pods_ok; then
  echo "[remote] ❌ MongoDB pods not healthy after first wait. Current state:"
  dump_mongo_pods

  if [[ -x ./uninstall_mongodb.sh ]]; then
    echo "[remote] Attempting MongoDB uninstall/reinstall…"
    ./uninstall_mongodb.sh
    ./install_mongodb.sh
    echo "[remote] Waiting 100s after MongoDB reinstall…"
    sleep 100
  else
    echo "[remote] ERROR: uninstall_mongodb.sh missing or not executable" >&2
    exit 7
  fi

  if ! mongo_pods_ok; then
    echo "[remote] ❌ MongoDB pods still not healthy after reinstall; aborting."
    dump_mongo_pods
    exit 8
  fi
fi
echo "[remote] ✅ MongoDB pods healthy (namespace mongodb: all pods Running & Ready)."

# ---- Make one Mongo PRIMARY via addmongoreplica.sh (retry ONLY if needed) ----
if [[ -x ./addmongoreplica.sh ]]; then
  echo "[remote] Running addmongoreplica.sh (attempt 1)…"
  ./addmongoreplica.sh | tee /tmp/addreplica1.log || true

  if grep -q "PRIMARY" /tmp/addreplica1.log; then
    echo "[remote] ✅ PRIMARY detected after attempt 1 — skipping second attempt."
  else
    echo "[remote] PRIMARY not detected after attempt 1 — waiting 8s and retrying…"
    sleep 8
    ./addmongoreplica.sh | tee /tmp/addreplica2.log || true
    if grep -q "PRIMARY" /tmp/addreplica2.log; then
      echo "[remote] ✅ PRIMARY detected after attempt 2."
    else
      echo "[remote] ⚠️  PRIMARY not detected after two attempts; continuing but please verify."
    fi
  fi
else
  echo "[remote] WARNING: addmongoreplica.sh not found or not executable; skipping PRIMARY setup."
fi

# ---- Copy & run load.sh ----
LOAD_SRC="${BASE}/TRILLIUM_5GCN_CNF_REL_${VER}/common/tools/install/load.sh"
LOAD_DST="${BASE}/load.sh"

if [[ ! -f "${LOAD_SRC}" ]]; then
  echo "[remote] ERROR: load.sh not found at ${LOAD_SRC}" >&2
  exit 9
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

# Iterate hosts with simple retry
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

# Gate on overall pod health after PS apply
ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${HOST_USER}@${RUNNER}" bash -lc '
  set -euo pipefail
  bad=0
  while read -r ns name ready status rest; do
    x="${ready%%/*}"; y="${ready##*/}"
    if [[ "$status" != "Running" || "$x" != "$y" ]]; then bad=1; fi
  done < <(kubectl get pods -A --no-headers)
  if [[ $bad -ne 0 ]]; then
    echo "[ps_config] ❌ Pods not healthy after PS"
    kubectl get pods -A || true
    exit 1
  fi
  echo "[ps_config] ✅ PS stage done"
'
