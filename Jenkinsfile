// ---------- Parameters (Active Choices enabled) ----------
properties([
  parameters([
    // Installation mode controls: reset gating + OLD_BUILD_PATH visibility
    choice(
      name: 'INSTALL_MODE',
      choices: 'Upgrade_with_cluster_reset\nUpgrade_without_cluster_reset\nFresh_installation',
      description: 'Select installation mode'
    ),

    choice(name: 'NEW_VERSION',
           choices: '6.2.0_EA6\n6.3.0\n6.3.0_EA1\n6.3.0_EA2',
           description: 'Target bundle (may have suffix, e.g., 6.3.0_EA2)'),

    choice(name: 'OLD_VERSION',
           choices: '6.2.0_EA6\n6.3.0\n6.3.0_EA1\n6.3.0_EA2',
           description: 'Existing bundle (used for Upgrade_* modes)'),

    // ▼ Conditionally visible OLD_BUILD_PATH using Active Choices
    [$class: 'DynamicReferenceParameter',
      name: 'OLD_BUILD_PATH_UI',
      description: 'Base dir of OLD_VERSION (shown only for Upgrade modes)',
      referencedParameters: 'INSTALL_MODE',
      script: [
        $class: 'GroovyScript',
        sandbox: true,
        script: '''
def mode = INSTALL_MODE ?: ''
if (mode == 'Fresh_installation') {
  return "" // hide the field
}
// Render a plain text input named "value" so Jenkins captures it as the parameter value
return """<input class='setting-input' name='value' type='text' value='/home/labadmin'/>"""
'''
      ],
      fallbackScript: [
        $class: 'GroovyScript',
        sandbox: true,
        script: 'return ""'
      ]
    ],

    string(name: 'NEW_BUILD_PATH',
           defaultValue: '/home/labadmin',
           description: 'Base dir to place NEW_VERSION (and extract)'),

    // Remote fetch (copy directly to CN servers)
    booleanParam(name: 'FETCH_BUILD',   defaultValue: true, description: 'Fetch NEW_VERSION from build host to CN servers'),
    choice(name: 'BUILD_SRC_HOST',
           choices: '172.26.2.96\n172.26.2.95',
           description: 'Build repo host'),
    choice(name: 'BUILD_SRC_USER',
           choices: 'sobirada\nlabadmin',
           description: 'Build repo user'),
    choice(name: 'BUILD_SRC_BASE',
           choices: '/CNBuild/6.3.0_EA2\n/CNBuild/6.3.0\n/CNBuild/6.3.0_EA1',
           description: 'Path on build host containing the tar.gz files'),
    password(name: 'BUILD_SRC_PASS', defaultValue: '', description: 'Build host password (optional; only for repo host)'),

    // Alias IP (CIDR) to plumb on CN servers (auto-detect interface on host)
    string(name: 'INSTALL_IP_ADDR', defaultValue: '10.10.10.20/24',
           description: 'Alias IP/CIDR to plumb on CN servers (interface auto-detected)')
  ])
])

// ---------------------------- Pipeline ----------------------------
pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    SERVER_FILE = 'server_pci_map.txt'
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key'   // CN servers use this key (root)
    K8S_VER     = '1.31.4'
    EXTRACT_BUILD_TARBALLS = 'false'                    // fetch: do NOT untar
    INSTALL_IP_ADDR  = "${params.INSTALL_IP_ADDR}"      // default can be overridden by param
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Validate inputs') {
      steps {
        script {
          // Require OLD_BUILD_PATH for Upgrade modes; ignore for Fresh_installation
          if (params.INSTALL_MODE != 'Fresh_installation') {
            if (!params.OLD_BUILD_PATH_UI?.trim()) {
              error "OLD_BUILD_PATH is required for ${params.INSTALL_MODE}"
            }
          }
        }
      }
    }

    stage('Reset &/or Fetch (parallel)') {
      parallel {
        stage('Cluster reset (auto from INSTALL_MODE)') {
          when {
            expression { return params.INSTALL_MODE == 'Upgrade_with_cluster_reset' }
          }
          steps {
            timeout(time: 15, unit: 'MINUTES', activity: true) {
              // We pass OLD_BUILD_PATH using the Active Choices value
              sh '''
                set -eu
                echo ">>> Cluster reset starting (INSTALL_MODE=Upgrade_with_cluster_reset)"
                sed -i 's/\\r$//' scripts/cluster_reset.sh || true
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
                sed -i 's/\\r$//' scripts/fetch_build.sh || true
                chmod +x scripts/fetch_build.sh

                # Password auth only for BUILD host (repo); CN login remains key-based
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
            sed -i 's/\\r$//' scripts/cluster_install.sh || true
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
  }

  post {
    always {
      archiveArtifacts artifacts: '**/*.log', allowEmptyArchive: true
    }
  }
}
