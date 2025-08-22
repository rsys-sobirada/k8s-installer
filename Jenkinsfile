// ================== Parameters ==================
properties([
  parameters([
    // 1) Deployment type
    choice(
      name: 'DEPLOYMENT_TYPE',
      choices: 'Low\nMedium\nHigh',
      description: 'Deployment type'
    ),

    // 2) Install mode (controls OLD_BUILD_PATH visibility)
    choice(
      name: 'INSTALL_MODE',
      choices: 'Upgrade_with_cluster_reset\nUpgrade_without_cluster_reset\nFresh_installation',
      description: 'Select installation mode'
    ),

    // 3) OLD_BUILD_PATH shown only for Upgrade_* modes (simple input)
    [
      $class: 'DynamicReferenceParameter',
      name: 'OLD_BUILD_PATH_UI',
      description: 'Base dir of OLD_VERSION (shown only for Upgrade modes)',
      referencedParameters: 'INSTALL_MODE',
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [
          script: '''
def mode = (INSTALL_MODE ?: "").toString()
if (mode == 'Fresh_installation') return ""
return """<input class='setting-input' name='value' type='text' value='/home/labadmin'/>"""
''',
          sandbox: true,
          classpath: []
        ],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    // 4) New build path
    string(name: 'NEW_BUILD_PATH',
           defaultValue: '/home/labadmin',
           description: 'Base dir to place NEW_VERSION (and extract)'),

    // 5) New version
    choice(name: 'NEW_VERSION',
           choices: '6.2.0_EA6\n6.3.0\n6.3.0_EA1\n6.3.0_EA2\n6.3.0_EA3',
           description: 'Target bundle (may have suffix, e.g., 6.3.0_EA2)'),

    // 6) Old version
    choice(name: 'OLD_VERSION',
           choices: '6.2.0_EA6\n6.3.0\n6.3.0_EA1\n6.3.0_EA2\n6.3.0_EA3',
           description: 'Existing bundle (used if upgrading)'),

    // 7) Fetch toggle
    booleanParam(name: 'FETCH_BUILD',
           defaultValue: true,
           description: 'Fetch NEW_VERSION from build host to CN servers'),

    // ---- Build source (dropdowns + optional custom overrides) ----
    choice(
      name: 'BUILD_SRC_HOST',
      choices: '172.26.2.96\n172.26.2.95',
      description: 'Build repo host (use custom field below to override)'
    ),
    string(
      name: 'BUILD_SRC_HOST_CUSTOM',
      defaultValue: '',
      description: 'Custom host/IP (leave empty to use dropdown)'
    ),

    choice(
      name: 'BUILD_SRC_USER',
      choices: 'sobirada\nlabadmin',
      description: 'Build repo user (use custom field below to override)'
    ),
    string(
      name: 'BUILD_SRC_USER_CUSTOM',
      defaultValue: '',
      description: 'Custom username (leave empty to use dropdown)'
    ),

    choice(
      name: 'BUILD_SRC_BASE',
      choices: '/CNBuild/6.3.0_EA2\n/CNBuild/6.3.0_EA3\n/CNBuild/6.3.0_EA1',
      description: 'Path on build host (use custom field below to override)'
    ),
    string(
      name: 'BUILD_SRC_BASE_CUSTOM',
      defaultValue: '',
      description: 'Custom path (leave empty to use dropdown)'
    ),

    // 11) Password (masked)
    password(
      name: 'BUILD_SRC_PASS',
      defaultValue: '',
      description: 'Build host password (for SCP/SSH from build repo)'
    ),

    // 12) Alias IP/CIDR
    string(name: 'INSTALL_IP_ADDR',
           defaultValue: '10.10.10.20/24',
           description: 'Alias IP/CIDR to plumb on CN servers'),

    // -------- OPTIONAL bootstrap controls --------
    password(
      name: 'CN_BOOTSTRAP_PASS',
      defaultValue: '',
      description: 'One-time CN root password (if you ever need sshpass locally). Not used by bootstrap_keys.sh.'
    )
  ])
])

// =================================== Pipeline ===================================
pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    SERVER_FILE = 'server_pci_map.txt'
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key'
    K8S_VER     = '1.31.4'
    EXTRACT_BUILD_TARBALLS = 'false'
    INSTALL_IP_ADDR  = '10.10.10.20/24'   // default; param overrides
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Validate inputs') {
      steps {
        script {
          if (params.INSTALL_MODE != 'Fresh_installation' && !params.OLD_BUILD_PATH_UI?.trim()) {
            error "OLD_BUILD_PATH is required for ${params.INSTALL_MODE}"
          }
        }
      }
    }

    // -------- Pre-bootstrap: Fresh_installation only --------
    stage('Pre-bootstrap keys (Fresh only)') {
      when { expression { return params.INSTALL_MODE == 'Fresh_installation' } }
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

: "${SERVER_FILE:?missing}"; : "${SSH_KEY:?missing}"; : "${INSTALL_IP_ADDR:?missing}"
ALIAS_IP="${INSTALL_IP_ADDR%%/*}"

HOSTS=$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){n=split($0,a,":"); print a[2]} else {print $1} }' "${SERVER_FILE}" | paste -sd " " -)
echo "[bootstrap][runner] Hosts: ${HOSTS}"
echo "[bootstrap][runner] Alias IP: ${ALIAS_IP}  (from ${INSTALL_IP_ADDR})"

bootstrap_one() {
  local host="$1"
  echo ""
  echo "─── Host ${host} ───────────────────────────────────────"

  SCRIPT_CONTENT='#!/usr/bin/env bash
set -euo pipefail
IP="$1"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -q -t rsa -N "" -f ~/.ssh/id_rsa
ssh-copy-id root@"${IP}"
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
ssh-keygen -f "/root/.ssh/known_hosts" -R "${IP}"
systemctl restart sshd
'

  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" bash -lc '
    set -euo pipefail
    cat > /root/bootstrap_keys.sh <<'"'"'EOF'"'"'
'"${SCRIPT_CONTENT}"'
EOF
    chmod +x /root/bootstrap_keys.sh
    [[ -s /root/bootstrap_keys.sh ]] && echo "✅ Script integrity OK on ${HOSTNAME}" || { echo "❌ Script not present"; exit 2; }
    /root/bootstrap_keys.sh "'"${ALIAS_IP}"'"
  '
}

for h in ${HOSTS}; do
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${h}" bash -lc '
    set -euo pipefail
    ip -4 addr show | awk "/inet /{print \\$2}" | grep -qx "'"${INSTALL_IP_ADDR}"'" || {
      DEFIF=$(ip route | awk "/^default/{print \\$5; exit}")
      ip link set dev "${DEFIF}" up || true
      ip addr replace "'"${INSTALL_IP_ADDR}"'" dev "${DEFIF}"
    }
    ip -4 addr show | grep -q "'"${INSTALL_IP_ADDR}"'" && echo "[IP] Present: ${INSTALL_IP_ADDR}" || { echo "[IP] Failed to plumb ${INSTALL_IP_ADDR}"; exit 2; }
  '
  bootstrap_one "$h"
done
'''
        }
      }
    }

    stage('Reset &/or Fetch (parallel)') {
      parallel {
        stage('Cluster reset (auto from INSTALL_MODE)') {
          when { expression { return params.INSTALL_MODE == 'Upgrade_with_cluster_reset' } }
          steps {
            timeout(time: 15, unit: 'MINUTES', activity: true) {
              sh '''
                set -eu
                echo ">>> Cluster reset starting (INSTALL_MODE=Upgrade_with_cluster_reset)"
                sed -i 's/\r$//' scripts/cluster_reset.sh || true
                chmod +x scripts/cluster_reset.sh
                env \
                  CLUSTER_RESET=true \
                  OLD_VERSION="${OLD_VERSION}" \
                  OLD_BUILD_PATH="${OLD_BUILD_PATH_UI}" \
                  K8S_VER="${K8S_VER}" \
                  KSPRAY_DIR="kubespray-2.27.0" \
                  RESET_YML_WS="$WORKSPACE/reset.yml" \
                  SSH_KEY="${SSH_KEY}" \
                  SERVER_FILE="${SERVER_FILE}" \
                  REQ_WAIT_SECS="360" \
                  RETRY_COUNT="3" \
                  RETRY_DELAY_SECS="10" \
                bash -euo pipefail scripts/cluster_reset.sh
              '''
            }
          }
        }

        stage('Fetch build to CN (optional)') {
          when { expression { return params.FETCH_BUILD } }
          steps {
            timeout(time: 20, unit: 'MINUTES', activity: true) {
              sh '''
                set -eu
                sed -i 's/\r$//' scripts/fetch_build.sh || true
                chmod +x scripts/fetch_build.sh

                # Compute effective values: custom overrides dropdowns if set
                BUILD_SRC_HOST_EFF="${BUILD_SRC_HOST_CUSTOM:-}"
                [ -n "$BUILD_SRC_HOST_EFF" ] || BUILD_SRC_HOST_EFF="${BUILD_SRC_HOST}"

                BUILD_SRC_USER_EFF="${BUILD_SRC_USER_CUSTOM:-}"
                [ -n "$BUILD_SRC_USER_EFF" ] || BUILD_SRC_USER_EFF="${BUILD_SRC_USER}"

                BUILD_SRC_BASE_EFF="${BUILD_SRC_BASE_CUSTOM:-}"
                [ -n "$BUILD_SRC_BASE_EFF" ] || BUILD_SRC_BASE_EFF="${BUILD_SRC_BASE}"

                if [ -n "${BUILD_SRC_PASS:-}" ]; then
                  if ! command -v sshpass >/dev/null 2>&1; then
                    echo "ERROR: sshpass is required on this agent for password-based SCP/SSH to BUILD_SRC_HOST." >&2
                    exit 2
                  fi
                fi

                echo "Targets from ${SERVER_FILE}:"
                awk 'NF && $1 !~ /^#/' "${SERVER_FILE}" || true

                NEW_VERSION="${NEW_VERSION}" \
                NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
                SERVER_FILE="${SERVER_FILE}" \
                BUILD_SRC_HOST="${BUILD_SRC_HOST_EFF}" \
                BUILD_SRC_USER="${BUILD_SRC_USER_EFF}" \
                BUILD_SRC_BASE="${BUILD_SRC_BASE_EFF}" \
                BUILD_SRC_PASS="${BUILD_SRC_PASS:-}" \
                CN_SSH_KEY="${SSH_KEY}" \
                EXTRACT_BUILD_TARBALLS="${EXTRACT_BUILD_TARBALLS}" \
                bash -euo pipefail scripts/fetch_build.sh
              '''
            }
          }
        }
      }
    }

    // -------- Cluster install with auto-retry on SSH permission denial --------
    stage('Cluster install') {
      steps {
        timeout(time: 20, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail
echo ">>> Cluster install starting (mode: ${INSTALL_MODE})"
sed -i 's/\r$//' scripts/cluster_install.sh || true
chmod +x scripts/cluster_install.sh

run_install() {
  env \
    NEW_VERSION="${NEW_VERSION}" \
    NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
    K8S_VER="${K8S_VER}" \
    KSPRAY_DIR="kubespray-2.27.0" \
    INSTALL_SERVER_FILE="${SERVER_FILE}" \
    INSTALL_IP_ADDR="${INSTALL_IP_ADDR}" \
    SSH_KEY="${SSH_KEY}" \
    INSTALL_MODE="${INSTALL_MODE}" \
    INSTALL_RETRY_COUNT="1" \
    INSTALL_RETRY_DELAY_SECS="10" \
    BUILD_WAIT_SECS="300" \
  bash -euo pipefail scripts/cluster_install.sh | tee /tmp/cluster_install.out
}

# 1st attempt
set +e
run_install
RC=$?
set -e

if grep -q "Permission denied (publickey,password)" /tmp/cluster_install.out; then
  echo "[auto-recovery] SSH permission denied detected → re-running bootstrap on each host and retrying install once."

  ALIAS_IP="${INSTALL_IP_ADDR%%/*}"
  HOSTS=$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){n=split($0,a,":"); print a[2]} else {print $1} }' "${SERVER_FILE}" | paste -sd " " -)
  for h in ${HOSTS}; do
    ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${h}" bash -lc '
      set -euo pipefail
      cat > /root/bootstrap_keys.sh <<'"'"'EOF'"'"'
#!/usr/bin/env bash
set -euo pipefail
IP="$1"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -q -t rsa -N "" -f ~/.ssh/id_rsa
ssh-copy-id root@"${IP}"
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
ssh-keygen -f "/root/.ssh/known_hosts" -R "${IP}"
systemctl restart sshd
EOF
      chmod +x /root/bootstrap_keys.sh
      /root/bootstrap_keys.sh "'"${ALIAS_IP}"'"
    '
  done

  # Retry once
  set +e
  run_install
  RC=$?
  set -e
fi

exit $RC
'''
        }
      }
    }

    // ---------- Cluster health check ----------
    stage('Cluster health check') {
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail
HOST="$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0) { n=split($0,a,":"); print $2; exit } else { print $1; exit } }' "${SERVER_FILE}")"
if [[ -z "${HOST}" ]]; then
  echo "[cluster-health] ERROR: could not parse host from ${SERVER_FILE}" >&2
  exit 2
fi
echo "[cluster-health] Using host ${HOST} for kubectl checks"

ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc '
  set -euo pipefail
  kubectl get nodes >/dev/null 2nd || { echo "[cluster-health] kubectl not yet available; treating as not-ready"; exit 0; }
  check() {
    local notok=0
    while read -r ns name ready status rest; do
      x="${ready%%/*}"; y="${ready##*/}"
      if [[ "$status" != "Running" || "$x" != "$y" ]]; then
        echo "[cluster-health] $ns/$name not healthy (READY=$ready STATUS=$status)"
        notok=1
      fi
    done < <(kubectl get pods -A --no-headers)
    return $notok
  }
  if check; then
    echo "[cluster-health] ✅ All pods Running & Ready."
  else
    echo "[cluster-health] Pods not healthy, waiting 300s and retrying..."
    sleep 300
    if check; then
      echo "[cluster-health] ✅ Healthy after retry."
    else
      echo "[cluster-health] ❌ Pods still not healthy after 5 minutes."
      kubectl get pods -A || true
      exit 1
    fi
  }
'
'''
        }
      }
    }

    // ---------- PS config & install ----------
    stage('PS config & install') {
      steps {
        timeout(time: 30, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

sed -i 's/\r$//' scripts/ps_config.sh || true
chmod +x scripts/ps_config.sh

env \
  SERVER_FILE="${SERVER_FILE}" \
  SSH_KEY="${SSH_KEY}" \
  NEW_VERSION="${NEW_VERSION}" \
  NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
  INSTALL_IP_ADDR="${INSTALL_IP_ADDR}" \
  DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE}" \
bash -euo pipefail scripts/ps_config.sh
'''
        }
      }
    }

    // ---------- PS health check ----------
    stage('PS health check') {
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail
HOST="$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0) { n=split($0,a,":"); print $2; exit } else { print $1; exit } }' "${SERVER_FILE}")"
if [[ -z "${HOST}" ]]; then
  echo "[ps-health] ERROR: could not parse host from ${SERVER_FILE}" >&2
  exit 2
fi
echo "[ps-health] Using host ${HOST} for kubectl checks"

ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc '
  set -euo pipefail
  kubectl get nodes >/dev/null 2>&1 || { echo "[ps-health] kubectl not yet available; treating as not-ready"; exit 0; }
  check() {
    local notok=0
    while read -r ns name ready status rest; do
      x="${ready%%/*}"; y="${ready##*/}"
      if [[ "$status" != "Running" || "$x" != "$y" ]]; then
        echo "[ps-health] $ns/$name not healthy (READY=$ready STATUS=$status)"
        notok=1
      fi
    done < <(kubectl get pods -A --no-headers)
    return $notok
  }
  if check; then
    echo "[ps-health] ✅ All pods Running & Ready."
  else
    echo "[ps-health] Pods not healthy, waiting 300s and retrying..."
    sleep 300
    if check; then
      echo "[ps-health] ✅ Healthy after retry."
    else
      echo "[ps-health] ❌ Pods still not healthy after 5 minutes."
      kubectl get pods -A || true
      exit 1
    fi
  }
'
'''
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: '**/*.log', allowEmptyArchive: true
    }
  }
}
