#!/usr/bin/env bash
set -euo pipefail

: "${SERVER_FILE:?missing}"
: "${SSH_KEY:?missing}"

# pick first target host from SERVER_FILE; supports "name:ip:..." or "ip"
HOST="$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0) { n=split($0,a,":"); print a[2]; exit } else { print $1; exit } }' "${SERVER_FILE}")"
if [[ -z "${HOST}" ]]; then
  echo "[health-check] ERROR: could not parse host from ${SERVER_FILE}" >&2
  exit 2
fi
echo "[health-check] Using host ${HOST} for kubectl checks"

ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc '
  set -euo pipefail
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
    kubectl get pods -A
    exit 1
  fi
'
