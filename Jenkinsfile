// ================== Parameters (Active Choices, ordered as requested) ==================
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

    // 3) OLD_BUILD_PATH shown only for Upgrade_* modes (kept for UI; reset script ignores it now)
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

    // 8) Host (visible only if FETCH_BUILD truthy)
    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_HOST',
      description: 'Build repo host',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [
          script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<select class='setting-input' name='value'>
           <option value="172.26.2.96">172.26.2.96</option>
           <option value="172.26.2.95">172.26.2.95</option>
         </select>"""
''',
          sandbox: true,
          classpath: []
        ],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    // 9) User (visible only if FETCH_BUILD truthy)
    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_USER',
      description: 'Build repo user',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [
          script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<select class='setting-input' name='value'>
           <option value="sobirada">sobirada</option>
           <option value="labadmin">labadmin</option>
         </select>"""
''',
          sandbox: true,
          classpath: []
        ],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    // 10) Base path (visible only if FETCH_BUILD truthy)
    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_BASE',
      description: 'Path on build host containing the tar.gz files',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [
          script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<select class='setting-input' name='value'>
           <option value="/CNBuild/6.3.0_EA2">/CNBuild/6.3.0_EA2</option>
           <option value="/CNBuild/6.3.0_EA3">/CNBuild/6.3.0_EA3</option>
           <option value="/CNBuild/6.3.0">/CNBuild/6.3.0</option>
           <option value="/CNBuild/6.3.0_EA1">/CNBuild/6.3.0_EA1</option>
         </select>"""
''',
          sandbox: true,
          classpath: []
        ],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    // 11) Password (Active Choices; conditional; visually masked)
    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_PASS',
      description: 'Build host password (for SCP/SSH from build repo)',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [
          script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<input type='password' class='setting-input' name='value' value=''/>"""
''',
          sandbox: true,
          classpath: []
        ],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    // 12) Alias IP/CIDR
    string(name: 'INSTALL_IP_ADDR',
           defaultValue: '10.10.10.20/24',
           description: 'Alias IP/CIDR to plumb on CN servers'),

    // -------- OPTIONAL bootstrap control (no defaultValue) --------
    password(
      name: 'CN_BOOTSTRAP_PASS',
      description: 'One-time CN root password (used to push Jenkins key if needed).'
    )
  ])
])

// =================================== Pipeline ===================================
pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    SERVER_FILE = 'server_pci_map.txt'
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key'   // root key used to reach CN
    K8S_VER     = '1.31.4'
    EXTRACT_BUILD_TARBALLS = 'false'
    INSTALL_IP_ADDR  = "${params.INSTALL_IP_ADDR}"      // ensure param override is available
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Show inputs') {
      steps {
        echo "INSTALL_MODE='${params.INSTALL_MODE}'  FETCH_BUILD='${params.FETCH_BUILD}'  NEW_VERSION='${params.NEW_VERSION}'  OLD_VERSION='${params.OLD_VERSION}'  INSTALL_IP_ADDR='${params.INSTALL_IP_ADDR}'"
      }
    }

    // ✅ Preflight: ensure SSH + ensure alias IP (add only if missing; IP-only check)
    stage('Preflight SSH to CNs') {
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail
: "${SERVER_FILE:?missing}"; : "${SSH_KEY:?missing}"; : "${INSTALL_IP_ADDR:?missing}"

PUB_KEY_FILE="${SSH_KEY}.pub"
if [ ! -s "${PUB_KEY_FILE}" ]; then
  echo "[preflight] Generating Jenkins SSH key at ${SSH_KEY} (no passphrase)…"
  install -m 700 -d "$(dirname "${SSH_KEY}")"
  ssh-keygen -q -t rsa -N "" -f "${SSH_KEY}"
fi

HOSTS=$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){n=split($0,a,":"); print a[2]} else {print $1} }' "${SERVER_FILE}" | paste -sd " " -)
[ -n "${HOSTS}" ] || { echo "[preflight] ERROR: No hosts parsed from ${SERVER_FILE}"; exit 2; }
echo "[preflight] Hosts: ${HOSTS}"

push_key_if_needed() {
  local host="$1"
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" true 2>/dev/null; then
    echo "[preflight] ${host}: ✅ key login OK"
    return 0
  fi
  if [ -n "${CN_BOOTSTRAP_PASS:-}" ]; then
    if ! command -v sshpass >/dev/null 2>&1; then
      echo "[preflight] ERROR: sshpass required but not installed on the Jenkins agent."
      exit 2
    fi
    echo "[preflight] ${host}: ⛏️ pushing Jenkins key via password…"
    sshpass -p "${CN_BOOTSTRAP_PASS}" \
      ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      "root@${host}" 'install -m700 -d /root/.ssh; touch /root/.ssh/authorized_keys; chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys'
    sshpass -p "${CN_BOOTSTRAP_PASS}" \
      scp -o StrictHostKeyChecking=no "${PUB_KEY_FILE}" "root@${host}:/root/.jenkins_key.pub.tmp"
    sshpass -p "${CN_BOOTSTRAP_PASS}" \
      ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      "root@${host}" 'grep -Fxf /root/.jenkins_key.pub.tmp /root/.ssh/authorized_keys >/dev/null || cat /root/.jenkins_key.pub.tmp >> /root/.ssh/authorized_keys; rm -f /root/.jenkins_key.pub.tmp'
    ssh-keygen -R "${host}" >/dev/null 2>&1 || true
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" 'echo "[preflight] ✅ key login OK on $(hostname)"'
  else
    echo "[preflight] ${host}: ❌ key login failed and CN_BOOTSTRAP_PASS not provided"
    return 1
  fi
}

# --- SSH key preflight ---
fail=0
for h in ${HOSTS}; do
  echo "[preflight] Testing ${h}…"
  push_key_if_needed "${h}" || fail=1
done

if [ "${fail}" -ne 0 ]; then
  echo "[preflight] ❌ One or more hosts failed SSH preflight."
  exit 1
fi

# --- Alias IP ensure (Option B: stream logs; capture SSH rc) ---
echo "[alias-ip] Ensuring ${INSTALL_IP_ADDR} on all CNs…"
fail=0
for h in ${HOSTS}; do
  echo "[alias-ip][${h}] ▶ start"
  set -o pipefail
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${h}" \
      "INSTALL_IP_ADDR='${INSTALL_IP_ADDR}' bash -s -- '${INSTALL_IP_ADDR}'" \
      2>&1 < scripts/alias_ip.sh | sed "s/^/[alias-ip][${h}] /"
  rc=${PIPESTATUS[0]:-$?}
  echo "[alias-ip][${h}] ◀ exit code=${rc}"
  [ "${rc}" -eq 0 ] || fail=1
done

[ "${fail:-0}" -eq 0 ] || { echo "[alias-ip] ❌ Failed to enforce alias IP on one or more CNs"; exit 1; }

echo "[preflight] ✅ All CNs accept Jenkins key & alias IP ensured. Proceeding."
'''
        }
      }
    }

    stage('Validate inputs') {
      steps {
        script {
          if ((params.INSTALL_MODE ?: '').toString().trim() != 'Fresh_installation' &&
              !((params.OLD_BUILD_PATH_UI ?: '').toString().trim())) {
            error "OLD_BUILD_PATH is required for ${params.INSTALL_MODE}"
          }
        }
      }
    }

    // -------- Pre-bootstrap: Fresh_installation only --------
    stage('Pre-bootstrap keys (Fresh only)') {
      when { expression { (params.INSTALL_MODE ?: '').toString().trim() == 'Fresh_installation' } }
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
  # ensure alias exists first so the ssh-copy-id step can reach it
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${h}" bash -lc '
    set -euo pipefail
    ip -4 addr show | awk "/inet /{print \\$2}" | grep -qx "'"${INSTALL_IP_ADDR}"'" || {
      DEFIF=$(ip route | awk "/^default/{print \\$5; exit}")
      ip link set dev "${DEFIF}" up || true
      ip addr add "'"${INSTALL_IP_ADDR}"'" dev "${DEFIF}"
    }
    ip -4 addr show | grep -q "'"${INSTALL_IP_ADDR}"'" && echo "[IP] Present: ${INSTALL_IP_ADDR}" || { echo "[IP] Failed to plumb ${INSTALL_IP_ADDR}"; exit 2; }
  '
  bootstrap_one "$h"
done
'''
        }
      }
    }

    // -------- Reset &/or Fetch (parallel) --------
    stage('Reset &/or Fetch (parallel)') {
      parallel {
        stage('Cluster reset (auto from INSTALL_MODE)') {
          when { expression { (params.INSTALL_MODE ?: '').toString().trim() == 'Upgrade_with_cluster_reset' } }
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

# Marker for downstream gating
touch "$WORKSPACE/.cluster_reset_done"
echo "[reset] Wrote marker $WORKSPACE/.cluster_reset_done"
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
BUILD_SRC_HOST="${BUILD_SRC_HOST}" \
BUILD_SRC_USER="${BUILD_SRC_USER}" \
BUILD_SRC_BASE="${BUILD_SRC_BASE}" \
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

    // -------- Cluster install gated on reset marker when required --------
    stage('Cluster install') {
      steps {
        timeout(time: 20, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

if [ "${INSTALL_MODE:-}" = "Upgrade_with_cluster_reset" ] && [ ! -f "$WORKSPACE/.cluster_reset_done" ]; then
  echo "[gate] INSTALL_MODE=Upgrade_with_cluster_reset but reset marker not found: $WORKSPACE/.cluster_reset_done"
  echo "[gate] This usually means the reset stage didn't run or failed."
  exit 2
fi

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

    // ---------- Health check after cluster install ----------
    stage('Cluster health check') {
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail
HOST="$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0) { n=split($0,a,":"); print a[2]; exit } else { print $1; exit } }' "${SERVER_FILE}")"
if [[ -z "${HOST}" ]]; then
  echo "[cluster-health] ERROR: could not parse host from ${SERVER_FILE}" >&2
  exit 2
fi
echo "[cluster-health] Using host ${HOST} for kubectl checks"

ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc '
  set -euo pipefail
  kubectl get nodes >/dev/null 2>&1 || { echo "[cluster-health] kubectl not yet available; treating as not-ready"; exit 0; }
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
HOST="$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0) { n=split($0,a,":"); print $1; exit } else { print $1; exit } }' "${SERVER_FILE}")"
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
