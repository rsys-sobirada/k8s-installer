#!/usr/bin/env bash
# cluster_pods_health_check.sh
# - Parses the first host from SERVER_FILE
# - Runs a remote health check via kubectl:
#     * healthy if all pods have READY m/n with m==n and no bad STATUS
#     * if not healthy, waits 300s and retries once
# - Exits 0 on healthy, 1 on unhealthy, 2 on parse error, 3 if kubectl missing

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

# Run the remote health check
set +e
ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc '
  set -euo pipefail

  # Ensure kubectl is present
  command -v kubectl >/dev/null 2>&1 || { echo "[health-check] ERROR: kubectl not found"; exit 3; }

  # Return 0 if healthy; 1 if any pod is not fully ready or has bad status
  check() {
    kubectl get pods -A --no-headers | awk '"'"'
      {
        # Columns (no headers): 1=NAMESPACE 2=NAME 3=READY 4=STATUS 5=RESTARTS 6=AGE
        split($3,a,"/");                 # READY m/n
        ready=(a[1]==a[2]);
        bad = ($4 ~ /(CrashLoopBackOff|ImagePullBackOff|BackOff|Error|Init:)/);  # STATUS
        if (!ready || bad) exit 1
      }
      END { exit 0 }
    '"'"'
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
'
RC=$?
set -e
exit $RC
