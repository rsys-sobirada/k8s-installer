#!/usr/bin/env bash
# scripts/k8s_health_check.sh
set -euo pipefail

: "${SERVER_FILE:?missing}"
: "${SSH_KEY:?missing}"
: "${TIMEOUT_SECS:=600}"     # total wait budget (seconds)
: "${SLEEP_SECS:=20}"        # interval between checks (seconds)
: "${KUBECONFIG_PATH:=/etc/kubernetes/admin.conf}"

# pick first target host from SERVER_FILE; supports "name:ip:..." or "ip"
HOST="$(awk 'NF && $1 !~ /^#/ {
  if (index($0,":")>0) { n=split($0,a,":"); print a[2]; exit } else { print $1; exit }
}' "${SERVER_FILE}")"

if [[ -z "${HOST}" ]]; then
  echo "[health-check] ERROR: could not parse host from ${SERVER_FILE}" >&2
  exit 2
fi
echo "[health-check] Using host ${HOST} for kubectl checks"

ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc "
  set -euo pipefail
  export KUBECONFIG='${KUBECONFIG_PATH}'

  # --- prerequisites ---
  if ! command -v kubectl >/dev/null 2>&1; then
    echo '[health-check] ❌ kubectl not found; cluster not installed correctly.'
    exit 1
  fi
  if [[ ! -s \"\$KUBECONFIG\" ]]; then
    echo \"[health-check] ❌ KUBECONFIG missing or empty: \$KUBECONFIG\"
    exit 1
  fi

  check_nodes_ready() {
    # return 0 if at least one node exists and all are Ready=True
    local j np nr
    if ! j=\$(kubectl get nodes -o json 2>/dev/null); then
      echo '[health-check] kubectl get nodes failed'
      return 1
    fi
    np=\$(printf '%s' \"\$j\" | jq -r '.items | length') || np=0
    if [[ \"\$np\" -lt 1 ]]; then
      echo '[health-check] No nodes found yet'
      return 1
    fi
    nr=\$(printf '%s' \"\$j\" | jq -r '[.items[] | any(.status.conditions[]; .type==\"Ready\" and .status==\"True\")] | all') || true
    if [[ \"\$nr\" == 'true' ]]; then
      return 0
    fi
    # print a compact status line per node
    kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}:{range .status.conditions[?(@.type==\"Ready\")]}{.status}{\"\\n\"}{end}{end}' \
      | sed 's/^/[health-check] node /'
    return 1
  }

  check_pods_ready() {
    # return 0 if all pods are Running and ready (x/y with x==y)
    local notok=0
    # shellcheck disable=SC2034
    while read -r ns name ready status rest; do
      [[ -z \"\$ns\" ]] && continue
      local x=\${ready%%/*} y=\${ready##*/}
      if [[ \"\$status\" != 'Running' || \"\$x\" != \"\$y\" ]]; then
        echo \"[health-check] POD not healthy: \${ns}/\${name} (READY=\$ready STATUS=\$status)\"
        notok=1
      fi
    done < <(kubectl get pods -A --no-headers 2>/dev/null || true)
    return \"\$notok\"
  }

  end=\$((SECONDS + ${TIMEOUT_SECS}))
  while (( SECONDS < end )); do
    if check_nodes_ready && check_pods_ready; then
      echo '[health-check] ✅ Cluster Ready: nodes Ready and all pods Running/Ready.'
      kubectl get nodes -o wide || true
      exit 0
    fi
    echo \"[health-check] Not ready yet at \$(date '+%F %T'); rechecking in ${SLEEP_SECS}s...\"
    sleep ${SLEEP_SECS}
  done

  echo '[health-check] ❌ Timed out waiting for readiness. Dumping diagnostics...'
  echo '--- nodes ---'
  kubectl get nodes -o wide || true
  echo '--- pods (all namespaces) ---'
  kubectl get pods -A -o wide || true
  echo '--- recent events (top 100) ---'
  kubectl get events -A --sort-by=.lastTimestamp | tail -n 100 || true

  # Try to show details for the first non-ready pod (if any)
  first_bad=\$(kubectl get pods -A --no-headers 2>/dev/null | awk '\$4 != \"Running\" || \$2 !~ /^[0-9]+\\/\\1\$/{print \$1\" \"\$2; exit}')
  if [[ -n \"\$first_bad\" ]]; then
    ns=\${first_bad%% *}; pod=\${first_bad##* }
    echo \"--- describe \${ns}/\${pod} ---\"
    kubectl -n \"\$ns\" describe pod \"\$pod\" || true
    echo \"--- logs (last 200 lines) \${ns}/\${pod} ---\"
    kubectl -n \"\$ns\" logs \"\$pod\" --tail=200 || true
  fi

  exit 1
"
