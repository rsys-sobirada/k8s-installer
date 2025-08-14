pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    SERVER_FILE = 'server_pci_map.txt'
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key'   // CN servers use this key (root)
    K8S_VER     = '1.31.4'
    EXTRACT_BUILD_TARBALLS = 'false'                    // fetch: do NOT untar
    INSTALL_IP_ADDR  = '10.10.10.20/24'
    INSTALL_IP_IFACE = ''                               // may be empty; keep defined
  }

  parameters {
    // ▼ New dropdown
    choice(
      name: 'DEPLOYMENT_TYPE',
      choices: 'Low\nMedium\nHigh',
      description: 'Deployment type'
    )

    // Main flow
    choice(name: 'NEW_VERSION',
           choices: '6.2.0_EA6\n6.3.0\n6.3.0_EA1\n6.3.0_EA2',
           description: 'Target bundle (may have suffix, e.g., 6.3.0_EA2)')
    choice(name: 'OLD_VERSION',
           choices: '6.2.0_EA6\n6.3.0'\n6.3.0_EA1\n6.3.0_EA2,
           description: 'Existing bundle (used if CLUSTER_RESET=true)')

    booleanParam(name: 'CLUSTER_RESET',  defaultValue: true,        description: 'Run cluster reset first')
    string      (name: 'OLD_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir of OLD_VERSION (for reset)')
    string      (name: 'NEW_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir to place NEW_VERSION (and extract)')

    // Remote fetch (copy directly to CN servers)
    booleanParam(name: 'FETCH_BUILD',   defaultValue: true, description: 'Fetch NEW_VERSION from build host to CN servers')
    choice(name: 'BUILD_SRC_HOST',
           choices: '172.26.2.96\n172.26.2.95',
           description: 'Build repo host')
    choice(name: 'BUILD_SRC_USER',
           choices: 'sobirada\nlabadmin',
           description: 'Build repo user')
    choice(name: 'BUILD_SRC_BASE',
           choices: '/CNBuild/6.3.0_EA2\n/CNBuild/6.3.0\n/CNBuild/6.3.0_EA1',
           description: 'Path on build host containing the tar.gz files')

    // Only BUILD host password from GUI (masked). May be empty.
    password(name: 'BUILD_SRC_PASS', defaultValue: '', description: 'Build host password (for SCP/SSH from build repo)')

    // Optional: pick interface for plumbing the alias IP
    choice(name: 'INSTALL_IP_IFACE',
           choices: '\nens160\neth0\nenp0s3',
           description: 'Interface to add 10.10.10.20/24 (leave blank to auto-detect)')
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Reset &/or Fetch (parallel)') {
      parallel {
        stage('Cluster reset (optional)') {
          when { expression { return params.CLUSTER_RESET } }
          steps {
            timeout(time: 15, unit: 'MINUTES', activity: true) {
              sh '''
                set -eu
                echo ">>> Cluster reset starting..."
                sed -i 's/\\r$//' scripts/cluster_reset.sh || true
                chmod +x scripts/cluster_reset.sh
                env \
                  CLUSTER_RESET=true \
                  OLD_VERSION="${OLD_VERSION}" \
                  OLD_BUILD_PATH="${OLD_BUILD_PATH}" \
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

                # We ONLY use password auth for the BUILD host.
                if [ -n "${BUILD_SRC_PASS:-}" ]; then
                  if ! command -v sshpass >/dev/null 2>&1; then
                    echo "ERROR: sshpass is required on this agent for password-based SCP/SSH to BUILD_SRC_HOST." >&2
                    exit 2
                  fi
                fi

                echo "Targets from ${SERVER_FILE}:"
                awk 'NF && $1 !~ /^#/' "${SERVER_FILE}" || true

                # CN login remains key-based (root) using SSH_KEY
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
            echo ">>> Cluster install starting..."
            sed -i 's/\\r$//' scripts/cluster_install.sh || true
            chmod +x scripts/cluster_install.sh
            env \
              NEW_VERSION="${NEW_VERSION}" \
              NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
              K8S_VER="${K8S_VER}" \
              KSPRAY_DIR="kubespray-2.27.0" \
              INSTALL_SERVER_FILE="${SERVER_FILE}" \
              INSTALL_IP_ADDR="${INSTALL_IP_ADDR}" \
              INSTALL_IP_IFACE="${INSTALL_IP_IFACE:-}" \
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
