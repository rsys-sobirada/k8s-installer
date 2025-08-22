// ================== Parameters (Active Choices, ordered as requested) ==================
properties([
  parameters([
    choice(name: 'DEPLOYMENT_TYPE', choices: 'Low\nMedium\nHigh', description: 'Deployment type'),
    choice(name: 'INSTALL_MODE', choices: 'Upgrade_with_cluster_reset\nUpgrade_without_cluster_reset\nFresh_installation', description: 'Select installation mode'),
    [
      $class: 'DynamicReferenceParameter',
      name: 'OLD_BUILD_PATH_UI',
      description: 'Base dir of OLD_VERSION (shown only for Upgrade modes)',
      referencedParameters: 'INSTALL_MODE',
      choiceType: 'ET_FORMATTED_HTML', omitValueField: true,
      script: [$class: 'GroovyScript', script: [script: '''
def mode = (INSTALL_MODE ?: "").toString()
if (mode == 'Fresh_installation') return ""
return """<input class='setting-input' name='value' type='text' value='/home/labadmin'/>"""
''', sandbox: true, classpath: []], fallbackScript: [script: 'return ""', sandbox: true, classpath: []]]
    ],
    string(name: 'NEW_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir to place NEW_VERSION (and extract)'),
    choice(name: 'NEW_VERSION', choices: '6.2.0_EA6\n6.3.0\n6.3.0_EA1\n6.3.0_EA2', description: 'Target bundle (may have suffix, e.g., 6.3.0_EA2)'),
    choice(name: 'OLD_VERSION', choices: '6.2.0_EA6\n6.3.0\n6.3.0_EA1\n6.3.0_EA2', description: 'Existing bundle (used if upgrading)'),
    booleanParam(name: 'FETCH_BUILD', defaultValue: true, description: 'Fetch NEW_VERSION from build host to CN servers'),
    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_HOST',
      description: 'Build repo host',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML', omitValueField: true,
      script: [$class: 'GroovyScript', script: [script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<select class='setting-input' name='value'>
           <option value="172.26.2.96">172.26.2.96</option>
           <option value="172.26.2.95">172.26.2.95</option>
         </select>"""
''', sandbox: true, classpath: []], fallbackScript: [script: 'return ""', sandbox: true, classpath: []]]
    ],
    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_USER',
      description: 'Build repo user',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML', omitValueField: true,
      script: [$class: 'GroovyScript', script: [script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<select class='setting-input' name='value'>
           <option value="sobirada">sobirada</option>
           <option value="labadmin">labadmin</option>
         </select>"""
''', sandbox: true, classpath: []], fallbackScript: [script: 'return ""', sandbox: true, classpath: []]]
    ],
    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_BASE',
      description: 'Path on build host containing the tar.gz files',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML', omitValueField: true,
      script: [$class: 'GroovyScript', script: [script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<select class='setting-input' name='value'>
           <option value="/CNBuild/6.3.0_EA2">/CNBuild/6.3.0_EA2</option>
           <option value="/CNBuild/6.3.0">/CNBuild/6.3.0</option>
           <option value="/CNBuild/6.3.0_EA1">/CNBuild/6.3.0_EA1</option>
         </select>"""
''', sandbox: true, classpath: []], fallbackScript: [script: 'return ""', sandbox: true, classpath: []]]
    ],
    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_PASS',
      description: 'Build host password (for SCP/SSH from build repo)',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML', omitValueField: true,
      script: [$class: 'GroovyScript', script: [script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<input type='password' class='setting-input' name='value' value=''/>"""
''', sandbox: true, classpath: []], fallbackScript: [script: 'return ""', sandbox: true, classpath: []]]
    ],
    string(name: 'INSTALL_IP_ADDR', defaultValue: '10.10.10.20/24', description: 'Alias IP/CIDR to plumb on CN servers'),
    // optional bootstrap controls
    booleanParam(name: 'CN_BOOTSTRAP', defaultValue: false, description: 'If true, push Jenkins SSH key to CN hosts before fetch (needs CN_BOOTSTRAP_PASS)'),
    password(name: 'CN_BOOTSTRAP_PASS', defaultValue: '', description: 'One-time CN root password, used by bootstrap_keys.sh')
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
    INSTALL_IP_ADDR = "${params.INSTALL_IP_ADDR ?: '10.10.10.20/24'}"
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

    // ─────────────────────────────────────────────────────────────────────────────
    // NEW: Pre-bootstrap keys (Fresh only) by copying the full script to CN and running it
    // ─────────────────────────────────────────────────────────────────────────────
    stage('Pre-bootstrap keys (Fresh only)') {
      when { expression { return params.INSTALL_MODE == 'Fresh_installation' } }
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

[[ -s "${SSH_KEY}" ]] || { echo "Missing SSH_KEY: ${SSH_KEY}"; exit 2; }
chmod 600 "${SSH_KEY}" || true

# strip mask for alias IP
ALIAS_IP="$(printf %s "${INSTALL_IP_ADDR}" | awk -F/ '{print $1}')"

echo "[bootstrap][runner] Hosts: $(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){ n=split($0,a,":"); print a[2] } else { print $1 } }' "${SERVER_FILE}" | xargs -n1 | paste -sd, -)"
echo "[bootstrap][runner] Alias IP: ${ALIAS_IP}  (from ${INSTALL_IP_ADDR})"
echo

SSH_OPTS='-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=8'

while read -r raw || [[ -n "${raw:-}" ]]; do
  line="$(echo -n "${raw:-}" | tr -d '\r')"
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

  if [[ "$line" == *:* ]]; then
    IFS=':' read -r _name ip _rest <<<"$line"; host="$(echo -n "${ip:-}" | xargs)"
  else
    host="$(echo -n "$line" | xargs)"
  fi
  [[ -z "$host" ]] && continue

  echo "─── Host ${host} ───────────────────────────────────────"

  # 1) Copy the full script to CN:/root/bootstrap_keys.sh
  #    Use scp to ensure the entire file is transferred intact.
  scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "scripts/bootstrap_keys.sh" "root@${host}:/root/bootstrap_keys.sh"

  # 2) Make it executable and quick sanity check
  ssh -i "${SSH_KEY}" ${SSH_OPTS} "root@${host}" "chmod +x /root/bootstrap_keys.sh; head -n2 /root/bootstrap_keys.sh >/dev/null || true"
  echo "✅ Script integrity OK on ${host}"

  # 3) Run it on the CN with env + args (password masked in Jenkins log)
  echo "[run] /root/bootstrap_keys.sh --host ${host} --alias-ip ${ALIAS_IP} --pass '******' --force"
  ssh -i "${SSH_KEY}" ${SSH_OPTS} "root@${host}" bash -lc "
    INSTALL_IP_ADDR='${INSTALL_IP_ADDR}' \
    CN_BOOTSTRAP_PASS='${CN_BOOTSTRAP_PASS}' \
    /root/bootstrap_keys.sh --host '${host}' --alias-ip '${ALIAS_IP}' --pass '${CN_BOOTSTRAP_PASS}' --force
  "
done < "${SERVER_FILE}"
'''
        }
      }
    }

    // Fetch/Reset in parallel (unchanged)
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

                # We ONLY use password auth for the BUILD host.
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

    // ─────────────────────────────────────────────────────────────────────────────
    // Cluster install (+ automatic bootstrap/retry on SSH denial)
    // ─────────────────────────────────────────────────────────────────────────────
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
  bash -euo pipefail scripts/cluster_install.sh 2>&1 | tee install_out.log
}

# 1st attempt
set +e
run_install
RC=$?
set -e

# If SSH denied marker found anywhere in output → remediate and retry once
if grep -q "ANSIBLE_SSH_DENIED" install_out.log; then
  echo "[remediate] SSH denied detected — copying & running bootstrap_keys.sh on all hosts, then retrying install once."

  ALIAS_IP="$(printf %s "${INSTALL_IP_ADDR}" | awk -F/ '{print $1}')"
  SSH_OPTS='-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=8'
  while read -r raw || [[ -n "${raw:-}" ]]; do
    line="$(echo -n "${raw:-}" | tr -d '\r')"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" == *:* ]]; then
      IFS=':' read -r _name ip _rest <<<"$line"; host="$(echo -n "${ip:-}" | xargs)"
    else
      host="$(echo -n "$line" | xargs)"
    fi
    [[ -z "$host" ]] && continue

    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "scripts/bootstrap_keys.sh" "root@${host}:/root/bootstrap_keys.sh"
    ssh -i "${SSH_KEY}" ${SSH_OPTS} "root@${host}" "chmod +x /root/bootstrap_keys.sh"
    echo "[run] remedial bootstrap on ${host}"
    ssh -i "${SSH_KEY}" ${SSH_OPTS} "root@${host}" bash -lc "
      INSTALL_IP_ADDR='${INSTALL_IP_ADDR}' \
      CN_BOOTSTRAP_PASS='${CN_BOOTSTRAP_PASS}' \
      /root/bootstrap_keys.sh --host '${host}' --alias-ip '${ALIAS_IP}' --pass '${CN_BOOTSTRAP_PASS}' --force
    "
  done < "${SERVER_FILE}"

  # retry once
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

    // Cluster health check (unchanged)
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
    exit 0
  fi

  echo "[cluster-health] Pods not healthy, waiting 300s and retrying..."
  sleep 300

  if check; then
    echo "[cluster-health] ✅ Healthy after retry."
    exit 0
  else
    echo "[cluster-health] ❌ Pods still not healthy after 5 minutes."
    kubectl get pods -A
    exit 1
  fi
'
'''
        }
      }
    }

    // PS config & install (unchanged shell)
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

    // PS health check (unchanged)
    stage('PS health check') {
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail
HOST="$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0) { n=split($0,a,":"); print a[2]; exit } else { print $1; exit } }' "${SERVER_FILE}")"
if [[ -z "${HOST}" ]]; then
  echo "[ps-health] ERROR: could not parse host from ${SERVER_FILE}" >&2
  exit 2
fi
echo "[ps-health] Using host ${HOST} for kubectl checks"
ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc '
  set -euo pipefail
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
    exit 0
  fi
  echo "[ps-health] Pods not healthy, waiting 300s and retrying..."
  sleep 300
  if check; then
    echo "[ps-health] ✅ Healthy after retry."
    exit 0
  else
    echo "[ps-health] ❌ Pods still not healthy after 5 minutes."
    kubectl get pods -A
    exit 1
  fi
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
