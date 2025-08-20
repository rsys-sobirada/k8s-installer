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

    // 3) OLD_BUILD_PATH shown only for Upgrade_* modes
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
           choices: '6.2.0_EA6\n6.3.0\n6.3.0_EA1\n6.3.0_EA2',
           description: 'Target bundle (may have suffix, e.g., 6.3.0_EA2)'),

    // 6) Old version
    choice(name: 'OLD_VERSION',
           choices: '6.2.0_EA6\n6.3.0\n6.3.0_EA1\n6.3.0_EA2',
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
           description: 'Alias IP/CIDR to plumb on CN servers')
  ])
])

// =================================== Pipeline ===================================
pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    SERVER_FILE = 'server_pci_map.txt'
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key'   // CN servers use this key (root)
    K8S_VER     = '1.31.4'
    EXTRACT_BUILD_TARBALLS = 'false'                    // fetch: do NOT untar
    INSTALL_IP_ADDR  = '10.10.10.20/24'                 // default; overridden by param in stage env
  }

  // NOTE: no parameters{} block here — using properties([...]) above.

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
              INSTALL_RETRY_COUNT="3" \
              INSTALL_RETRY_DELAY_SECS="20" \
              BUILD_WAIT_SECS="300" \
            bash -euo pipefail scripts/cluster_install.sh
          '''
        }
      }
    }

    // ---------- Health check after cluster install (bash shebang) ----------
    stage('Cluster health check') {
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

NOT_OK=0
while read -r ns name ready status rest; do
  x="${ready%%/*}"; y="${ready##*/}"
  if [[ "$status" != "Running" || "$x" != "$y" ]]; then
    echo "[cluster-health] $ns/$name not healthy (READY=$ready STATUS=$status)"
    NOT_OK=1
  fi
done < <(kubectl get pods -A --no-headers)

if [[ "$NOT_OK" -eq 0 ]]; then
  echo "[cluster-health] ✅ All pods Running & Ready."
  exit 0
fi

echo "[cluster-health] Pods not healthy, waiting 300s and retrying..."
sleep 300

NOT_OK=0
while read -r ns name ready status rest; do
  x="${ready%%/*}"; y="${ready##*/}"
  if [[ "$status" != "Running" || "$x" != "$y" ]]; then
    echo "[cluster-health] (retry) $ns/$name still not healthy (READY=$ready STATUS=$status)"
    NOT_OK=1
  fi
done < <(kubectl get pods -A --no-headers)

if [[ "$NOT_OK" -ne 0 ]]; then
  echo "[cluster-health] ❌ Pods still not healthy after 5 minutes."
  kubectl get pods -A
  exit 1
fi

echo "[cluster-health] ✅ Healthy after retry."
'''
        }
      }
    }

    // ---------- PS config & install (separate script) ----------
    stage('PS config & install') {
      steps {
        timeout(time: 30, unit: 'MINUTES', activity: true) {
          sh '''
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

    // ---------- Health check after PS install (bash shebang) ----------
    stage('PS health check') {
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

NOT_OK=0
while read -r ns name ready status rest; do
  x="${ready%%/*}"; y="${ready##*/}"
  if [[ "$status" != "Running" || "$x" != "$y" ]]; then
    echo "[ps-health] $ns/$name not healthy (READY=$ready STATUS=$status)"
    NOT_OK=1
  fi
done < <(kubectl get pods -A --no-headers)

if [[ "$NOT_OK" -eq 0 ]]; then
  echo "[ps-health] ✅ All pods Running & Ready."
  exit 0
fi

echo "[ps-health] Pods not healthy, waiting 300s and retrying..."
sleep 300

NOT_OK=0
while read -r ns name ready status rest; do
  x="${ready%%/*}"; y="${ready##*/}"
  if [[ "$status" != "Running" || "$x" != "$y" ]]; then
    echo "[ps-health] (retry) $ns/$name still not healthy (READY=$ready STATUS=$status)"
    NOT_OK=1
  fi
done < <(kubectl get pods -A --no-headers)

if [[ "$NOT_OK" -ne 0 ]]; then
  echo "[ps-health] ❌ Pods still not healthy after 5 minutes."
  kubectl get pods -A
  exit 1
fi

echo "[ps-health] ✅ Healthy after retry."
'''
        }
      }
    }

    // (You can add CS/NF stages next using the same pattern.)
  }

  post {
    always {
      archiveArtifacts artifacts: '**/*.log', allowEmptyArchive: true
    }
  }
}
