#!/usr/bin/env bash
set -euo pipefail

WAIT_SECS="${WAIT_SECS:-300}"   # default wait 5 min
SLEEP_SECS=300

echo "[health-check] Checking pod/container health..."

check_pods() {
  # require all pods running and ready
  local notok=0
  while IFS= read -r line; do
    ns=$(awk '{print $1}' <<<"$line")
    name=$(awk '{print $2}' <<<"$line")
    ready=$(awk '{print $3}' <<<"$line")
    status=$(awk '{print $4}' <<<"$line")

    # READY format X/Y
    x="${ready%%/*}"
    y="${ready##*/}"

    if [[ "$status" != "Running" || "$x" != "$y" ]]; then
      echo "[health-check] Pod $ns/$name not healthy (READY=$ready STATUS=$status)"
      notok=1
    fi
  done < <(kubectl get pods -A --no-headers)
  return $notok
}

# First check
if check_pods; then
  echo "[health-check] ✅ All pods are Running and Ready."
  exit 0
fi

echo "[health-check] Pods not healthy. Waiting ${WAIT_SECS}s and retrying..."
sleep "$SLEEP_SECS"

# Retry after wait
if check_pods; then
  echo "[health-check] ✅ All pods healthy after wait."
  exit 0
else
  echo "[health-check] ❌ Pods still not healthy after ${WAIT_SECS}s."
  kubectl get pods -A
  exit 1
fi
