pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    SERVER_FILE = 'server_pci_map.txt'
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key' // used for CN servers (root@host)
    K8S_VER     = '1.31.4'
    EXTRACT_BUILD_TARBALLS = 'false'                  // fetch: copy only (no untar)
  }

  parameters {
    // Main flow
    string(name: 'NEW_VERSION',    defaultValue: '6.3.0_EA2',  description: 'Target bundle (e.g., 6.3.0_EA2)')
    string(name: 'OLD_VERSION',    defaultValue: '6.3.0_EA1',  description: 'Existing bundle (used if CLUSTER_RESET=true)')
    booleanParam(name: 'CLUSTER_RESET', defaultValue: true,    description: 'Run cluster reset first')
    string(name: 'OLD_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir of OLD_VERSION (for reset)')
    string(name: 'NEW_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir where builds reside (or will be copied)')

    // Optional remote fetch (copy builds directly to CN servers)
    booleanParam(name: 'FETCH_BUILD', defaultValue: true, description: 'Fetch NEW_VERSION from build host to CN servers (in parallel)')
    string(name: 'BUILD_SRC_HOST', defaultValue: '172.26.2.96',     description: 'Build repo host')
    string(name: 'BUILD_SRC_USER', defaultValue: 'labadmin',        description: 'Build repo user')
    string(name: 'BUILD_SRC_BASE', defaultValue: '/CNBuild/6.3.0_EA2', description: 'Path on build host with tar.gz files')
    // Credentials needed:
    // - build-src-creds : username/password for BUILD_SRC_HOST
    // - cn-ssh-key      : SSH private key for CN servers (root@host)
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
            sh '''
              set -e
              echo ">>> Cluster reset starting..."
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
              bash -euo pipefail scripts/cluster_reset.sh
            '''
          }
        }

        stage('Fetch build to CN (optional)') {
          when { expression { return params.FETCH_BUILD } }
          steps {
            withCredentials([
              usernamePassword(credentialsId: 'build-src-creds', usernameVariable: 'BUILD_SRC_USER', passwordVariable: 'BUILD_SRC_PASS'),
              sshUserPrivateKey(credentialsId: 'cn-ssh-key', keyFileVariable: 'CN_KEY', usernameVariable: 'CN_USER')
            ]) {
              sh '''
                set -euo pipefail

                # Normalize endings so bash parses cleanly
                sed -i 's/\\r$//' scripts/fetch_build.sh || true
                chmod +x scripts/fetch_build.sh

                # sshpass only needed if BUILD_SRC_PASS is used to reach build host
                if [ -n "${BUILD_SRC_PASS:-}" ]; then
                  command -v sshpass >/dev/null 2>&1 || { echo "ERROR: install sshpass on agent"; exit 2; }
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
                # CN login via SSH key (matches cluster_reset/cluster_install)
                CN_USER="${CN_USER}" \
                CN_KEY="${CN_KEY}" \
                EXTRACT_BUILD_TARBALLS="false" \
                bash -euo pipefail scripts/fetch_build.sh
              '''
            }
          }
        }
      } // end parallel
    }

    stage('Cluster install') {
      steps {
        sh '''
          set -e
          echo ">>> Cluster install starting..."
          chmod +x scripts/cluster_install.sh
          env \
            NEW_VERSION="${NEW_VERSION}" \
            NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
            K8S_VER="${K8S_VER}" \
            KSPRAY_DIR="kubespray-2.27.0" \
            INSTALL_SERVER_FILE="${SERVER_FILE}" \
            INSTALL_IP_ADDR="10.10.10.20/24" \
            INSTALL_IP_IFACE="" \
            SSH_KEY="${SSH_KEY}" \
          bash -euo pipefail scripts/cluster_install.sh
        '''
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: '**/*.log', allowEmptyArchive: true
    }
  }
}
