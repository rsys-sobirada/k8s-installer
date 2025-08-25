#!/usr/bin/env bash
# k8s_health_check.sh
# - Parses the first host from SERVER_FILE
# - Remotely checks that all pods are READY (m/n equal) with no bad STATUS
# - If not healthy, waits 300s and retries once
# - Exit codes: 0 healthy, 1 unhealthy, 2 parse error, 3 kubectl missing

set -euo pipefail

: "${SERVER_FILE:?missing}"
: "${SSH_KEY:?missing}"

HOST="$(
  awk 'NF && $1 !~ /^#/ {
         if (index($0,":")>0){ n=split($0,a,":"); print a[2]; exit }
         else                { print $1;        exit }
       }' "${SERVER_FILE}"
)"

[[ -n "${HOST}" ]] || { echo "[health-check] ERROR: could not parse host"; exit 2; }
echo "[health-check] Using host ${HOST} for kubectl checks"

# Run the remote health check via a single-quoted heredoc so $3/$4 are not expanded by the shell
set +e
ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -s <<'REMOTE'
set -euo pipefail

# Ensure kubectl is present
command -v kubectl >/dev/null 2>&1 || { echo "[health-check] ERROR: kubectl not found"; exit 3; }

check() {
  # Healthy if every pod is READY m/n with m==n and no bad STATUS
  kubectl get pods -A --no-headers 2>/dev/null | awk '
    {
      # Columns: 1=NAMESPACE 2=NAME 3=READY 4=STATUS 5=RESTARTS 6=AGE
      split($3,a,"/");                 # READY m/n
      ready=(a[1]==a[2]);
      bad = ($4 ~ /(CrashLoopBackOff|ImagePullBackOff|BackOff|Error|Init:)/);
      if (!ready || bad) exit 1
    }
    END { exit 0 }'
}

if check; then
  echo "[health-check] ✅ All pods Running & Ready."
  exit 0
fi

echo "[health-check] Pods not healthy, waiting 300s and retrying..."
sleep 300

if check; then
  echo "[health-check] ✅ Healthy after retry."
  exit 0
else
  echo "[health-check] ❌ Pods still not healthy after 5 minutes."
  kubectl get pods -A || true
  exit 1
fi
REMOTE
RC=$?
set -e
exit $RC
