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
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [ script: '''
def mode = (INSTALL_MODE ?: "").toString()
if (mode == 'Fresh_installation') return ""
return """<input class='setting-input' name='value' type='text' value='/home/labadmin'/>"""
''', sandbox: true, classpath: []],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
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
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [ script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<select class='setting-input' name='value'>
           <option value="172.26.2.96">172.26.2.96</option>
           <option value="172.26.2.95">172.26.2.95</option>
         </select>"""
''', sandbox: true, classpath: []],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_USER',
      description: 'Build repo user',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [ script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<select class='setting-input' name='value'>
           <option value="sobirada">sobirada</option>
           <option value="labadmin">labadmin</option>
         </select>"""
''', sandbox: true, classpath: []],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_BASE',
      description: 'Path on build host containing the tar.gz files',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [ script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<select class='setting-input' name='value'>
           <option value="/CNBuild/6.3.0_EA2">/CNBuild/6.3.0_EA2</option>
           <option value="/CNBuild/6.3.0">/CNBuild/6.3.0</option>
           <option value="/CNBuild/6.3.0_EA1">/CNBuild/6.3.0_EA1</option>
         </select>"""
''', sandbox: true, classpath: []],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_PASS',
      description: 'Build host password (for SCP/SSH from build repo)',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [ script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<input type='password' class='setting-input' name='value' value=''/>"""
''', sandbox: true, classpath: []],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    string(name: 'INSTALL_IP_ADDR', defaultValue: '10.10.10.20/24', description: 'Alias IP/CIDR to plumb on CN servers'),

    // Bootstrap pass used by scripts/bootstrap_keys.sh
    password(name: 'CN_BOOTSTRAP_PASS', defaultValue: '', description: 'One-time CN root password used by bootstrap_keys.sh')
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
    INSTALL_IP_ADDR  = '10.10.10.20/24'
  }

  stages {
    stage('Checkout') { steps { checkout scm } }

    stage('Validate inputs') {
      steps {
        script {
          if (params.INSTALL_MODE != 'Fresh_installation' && !params.OLD_BUILD_PATH_UI?.trim()) {
            error "OLD_BUILD_PATH is required for ${params.INSTALL_MODE}"
          }
        }
      }
    }

    // NEW: Dedicated bootstrap stage using scripts/bootstrap_keys.sh
    stage('Bootstrap CN (keys & alias IP)') {
      when { expression { return params.INSTALL_MODE == 'Fresh_installation' } }
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

: "${SERVER_FILE:?missing SERVER_FILE}"
: "${SSH_KEY:?missing SSH_KEY}"
: "${INSTALL_IP_ADDR:?missing INSTALL_IP_ADDR}"
: "${CN_BOOTSTRAP_PASS:?missing CN_BOOTSTRAP_PASS}"

# Run the bootstrap across all hosts in SERVER_FILE (script handles parsing)
chmod +x scripts/bootstrap_keys.sh
SERVER_FILE="${SERVER_FILE}" \
SSH_KEY="${SSH_KEY}" \
INSTALL_IP_ADDR="${INSTALL_IP_ADDR}" \
CN_BOOTSTRAP_PASS="${CN_BOOTSTRAP_PASS}" \
scripts/bootstrap_keys.sh
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
            timeout(time: 15, unit: 'MINUTES', activity: true) {
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

    stage('Cluster install') {
      steps {
        timeout(time: 15, unit: 'MINUTES', activity: true) {
          sh '''
            set -eu
            echo ">>> Cluster install starting (mode: ${INSTALL_MODE})"
            sed -i 's/\r$//' scripts/cluster_install.sh || true
            chmod +x scripts/cluster_install.sh
            env \
              NEW_VERSION="${NEW_VERSION}" \
              NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
              K8S_VER="${K8S_VER}" \
              KSPRAY_DIR="kubespray-2.27.0" \
              INSTALL_SERVER_FILE="${SERVER_FILE}" \
              INSTALL_IP_ADDR="${INSTALL_IP_ADDR}" \
              SSH_KEY="${SSH_KEY}" \
              INSTALL_MODE="${INSTALL_MODE}" \
              INSTALL_RETRY_COUNT="3" \
              INSTALL_RETRY_DELAY_SECS="20" \
              BUILD_WAIT_SECS="300" \
            bash -euo pipefail scripts/cluster_install.sh
          '''
        }
      }
    }

    stage('Cluster health check') {
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

HOST="$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0) { n=split($0,a,":"); print a[2]; exit } else { print $1; exit } }' "${SERVER_FILE}")"
[[ -n "${HOST}" ]] || { echo "[cluster-health] ERROR: could not parse host from ${SERVER_FILE}" >&2; exit 2; }
echo "[cluster-health] Using host ${HOST} for kubectl checks"

# strict health check: fail if kubectl missing
set +e
ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc '
  set -euo pipefail
  command -v kubectl >/dev/null 2>&1 || { echo "[cluster-health] ERROR: kubectl not found"; exit 3; }
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
  if check; then echo "[cluster-health] ✅ All pods Running & Ready."; exit 0; fi
  echo "[cluster-health] Pods not healthy, waiting 300s and retrying..."; sleep 300
  if check; then echo "[cluster-health] ✅
