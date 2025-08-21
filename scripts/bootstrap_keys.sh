stage('Bootstrap CN') {
  when {
    expression { return params.INSTALL_MODE == 'Fresh_installation' }
  }
  steps {
    timeout(time: 10, unit: 'MINUTES', activity: true) {
      sh '''#!/usr/bin/env bash
set -euo pipefail

: "${SERVER_FILE:?missing SERVER_FILE}"
: "${SSH_KEY:?missing SSH_KEY}"
: "${INSTALL_IP_ADDR:?missing INSTALL_IP_ADDR}"
: "${CN_BOOTSTRAP_PASS:=root123}"

# Get first CN host from server_pci_map.txt
HOST="$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0) { split($0,a,":"); print a[2]; exit } else { print $1; exit } }' "${SERVER_FILE}")"
[[ -n "${HOST}" ]] || { echo "[bootstrap] ERROR: no host parsed from ${SERVER_FILE}" >&2; exit 2; }

# Strip /CIDR for alias
ALIAS_IP="${INSTALL_IP_ADDR%%/*}"

echo "[bootstrap] CN host: ${HOST}"
echo "[bootstrap] Alias IP: ${ALIAS_IP} (from ${INSTALL_IP_ADDR})"

# Copy bootstrap_keys.sh (already in Jenkins workspace) to CN
scp -o StrictHostKeyChecking=no -i "${SSH_KEY}" bootstrap_keys.sh "root@${HOST}:/root/bootstrap_keys.sh"

# Run it locally on CN
ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc "
  chmod +x /root/bootstrap_keys.sh &&
  CN_BOOTSTRAP_PASS='${CN_BOOTSTRAP_PASS}' \\
  SSH_KEY='${SSH_KEY}' \\
  /root/bootstrap_keys.sh --host '${HOST}' --alias-ip '${ALIAS_IP}' --pass '${CN_BOOTSTRAP_PASS}' --force
"
'''
    }
  }
}
