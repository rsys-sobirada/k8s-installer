pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    SERVER_FILE = 'server_pci_map.txt'
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key'   // key for CN reset/install (root@host)
    K8S_VER     = '1.31.4'
    EXTRACT_BUILD_TARBALLS = 'false'                    // fetch: do NOT untar
    INSTALL_IP_ADDR = '10.10.10.20/24'
    INSTALL_IP_IFACE = ''
  }

  parameters {
    // Main flow
    string      (name: 'NEW_VERSION',    defaultValue: '6.3.0_EA2', description: 'Target bundle (may have suffix, e.g., 6.3.0_EA2)')
    string      (name: 'OLD_VERSION',    defaultValue: '6.3.0_EA1', description: 'Existing bundle (used if CLUSTER_RESET=true)')
    booleanParam(name: 'CLUSTER_RESET',  defaultValue: true,        description: 'Run cluster reset first')
    string      (name: 'OLD_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir of OLD_VERSION (for reset)')
    string      (name: 'NEW_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir to place NEW_VERSION (and extract)')

    // Remote fetch (copy directly to CN servers)
    booleanParam(name: 'FETCH_BUILD', defaultValue: true, description: 'Fetch NEW_VERSION from build host to CN servers')
    string      (name: 'BUILD_SRC_HOST', defaultValue: '172.26.2.96',     description: 'Build repo host')
    string      (name: 'BUILD_SRC_USER', defaultValue: 'labadmin',         description: 'Build repo user')
    string      (name: 'BUILD_SRC_BASE', defaultValue: '/CNBuild/6.3.0_EA2', description: 'Path on build host containing the tar.gz files')
    // Required Jenkins Credentials (configure in Jenkins > Manage Credentials):
    // - build-src-creds : Username/Password for the build host (to SCP from)
    // - cn-pass         : Username/Password for CN servers (to SCP to)
    // - cn-ssh-key      : SSH private key for CN servers (root@host) used by reset/install
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
                set -e
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
              withCredentials([
                usernamePassword(credentialsId: 'build-src-creds', usernameVariable: 'BUILD_SRC_USER', passwordVariable: 'BUILD_SRC_PASS'),
                usernamePassword(credentialsId: 'cn-pass',         usernameVariable: 'CN_USER',         passwordVariable: 'CN_PASS'),
                sshUserPrivateKey(credentialsId: 'cn-ssh-key', keyFileVariable: 'CN_KEY', usernameVariable: 'CN_KEY_USER')
              ]) {
                sh '''
                  set -euo pipefail
                  # Ensure scripts are clean and executable
                  sed -i 's/\\r$//' scripts/fetch_build.sh || true
                  chmod +x scripts/fetch_build.sh

                  # Password-based SCP requires sshpass on the Jenkins agent
                  if [ -n "${BUILD_SRC_PASS:-}" ] || [ -n "${CN_PASS:-}" ]; then
                    command -v sshpass >/dev/null 2>&1 || { echo "ERROR: sshpass is required on this agent"; exit 2; }
                  fi

                  echo "Targets from ${SERVER_FILE}:"
                  awk 'NF && $1 !~ /^#/' "${SERVER_FILE}" || true

                  NEW_VERSION="${NEW_VERSION}" \
                  NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
                  SERVER_FILE="${SERVER_FILE}" \
                  BUILD_SRC_HOST="${BUILD_SRC_HOST}" \
                  BUILD_SRC_USER="${BUILD_SRC_USER}" \
                  BUILD_SRC_BASE="${BUILD_SRC_BASE}" \
                  BUILD_SRC_PASS="${BUILD_SRC_PASS}" \
                  CN_USER="${CN_USER}" \
                  CN_PASS="${CN_PASS}" \
                  EXTRACT_BUILD_TARBALLS="${EXTRACT_BUILD_TARBALLS}" \
                  bash -euo pipefail scripts/fetch_build.sh
                '''
              }
            }
          }
        }
      }
    }

    stage('Cluster install') {
      steps {
        timeout(time: 15, unit: 'MINUTES', activity: true) {
          sh '''
            set -e
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
              INSTALL_IP_IFACE="${INSTALL_IP_IFACE}" \
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
