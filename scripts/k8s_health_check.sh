#!/usr/bin/env bash
set -euo pipefail
: "${SERVER_FILE:?missing}"; : "${SSH_KEY:?missing}"

HOST="$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0) { n=split($0,a,":"); print a[2]; exit } else { print $1; exit } }' "${SERVER_FILE}")"
[[ -n "${HOST}" ]] || { echo "[health-check] ERROR: could not parse host"; exit 2; }
echo "[health-check] Using host ${HOST} for kubectl checks"

set +e
ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc '
  set -euo pipefail
  command -v kubectl >/dev/null 2>&1 || { echo "[health-check] ERROR: kubectl not found"; exit 3; }
  check() {
    local notok=0
    while read -r ns name ready status rest; do
      x="${ready%%/*}"; y="${ready##*/}"
      if [[ "$status" != "Running" || "$x" != "$y" ]]; then
        echo "[health-check] $ns/$name not healthy (READY=$ready STATUS=$status)"
        notok=1
      fi
    done < <(kubectl get pods -A --no-headers)
    return $notok
  }
  if check; then
    echo "[health-check] ✅ All pods Running & Ready."; exit 0
  fi
  echo "[health-check] Pods not healthy, waiting 300s and retrying..."; sleep 300
  if check; then
    echo "[health-check] ✅ Healthy after retry."; exit 0
  else
    echo "[health-check] ❌ Pods still not healthy after 5 minutes."
    kubectl get pods -A || true
    exit 1
  fi
'
RC=$?
set -e
exit $RC
