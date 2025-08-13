pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    SERVER_FILE = 'server_pci_map.txt'
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key' // used for target servers
    K8S_VER     = '1.31.4'
  }

  parameters {
    // Main flow
    string(name: 'NEW_VERSION',    defaultValue: '6.3.0_EA2',  description: 'Target bundle (may have suffix, e.g., 6.3.0_EA2)')
    string(name: 'OLD_VERSION',    defaultValue: '6.3.0_EA1',  description: 'Existing bundle (used if CLUSTER_RESET=true)')
    booleanParam(name: 'CLUSTER_RESET', defaultValue: true,    description: 'Run cluster reset first')
    string(name: 'OLD_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir of OLD_VERSION (for reset)')
    string(name: 'NEW_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir to place NEW_VERSION (and extract)')

    // Optional remote fetch (password-based SCP)
    booleanParam(name: 'FETCH_BUILD', defaultValue: false, description: 'Fetch NEW_VERSION from a remote host before install')
    string(name: 'BUILD_SRC_HOST', defaultValue: '',             description: 'Remote host (required if FETCH_BUILD=true)')
    string(name: 'BUILD_SRC_USER', defaultValue: 'labadmin',     description: 'Remote user')
    string(name: 'BUILD_SRC_BASE', defaultValue: '/repo/builds', description: 'Exact remote path containing TRILLIUM/BIN tar.gz files')
    password(name: 'BUILD_SRC_PASS', defaultValue: '',           description: 'Remote user password (required if FETCH_BUILD=true)')
  }

  stages {
    stage('Checkout') { steps { checkout scm } }

    stage('Fetch build (optional)') {
      // ✅ Only check FETCH_BUILD here. Validate password inside the step.
      when { expression { return params.FETCH_BUILD } }
      steps {
        sh '''
          set -e

          # Validate required inputs (don’t .trim() secrets in Groovy)
          if [ -z "${BUILD_SRC_HOST}" ]; then
            echo "ERROR: BUILD_SRC_HOST is required when FETCH_BUILD=true" >&2
            exit 2
          fi
          if [ -z "${BUILD_SRC_PASS}" ]; then
            echo "ERROR: BUILD_SRC_PASS is required when FETCH_BUILD=true" >&2
            exit 2
          fi

          # sshpass must exist for password-based scp/ssh
          if ! command -v sshpass >/dev/null 2>&1 ; then
            echo "ERROR: sshpass is required on this Jenkins agent for password-based SCP." >&2
            exit 2
          fi

          # Ensure LF endings (strip Windows CRLF if the file came in that way)
          sed -i 's/\\r$//' scripts/fetch_build.sh || true

          chmod +x scripts/fetch_build.sh

          # 👇 Run with bash explicitly (minimal alternative fix)
          NEW_VERSION="${NEW_VERSION}" \
          NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
          BUILD_SRC_HOST="${BUILD_SRC_HOST}" \
          BUILD_SRC_USER="${BUILD_SRC_USER}" \
          BUILD_SRC_BASE="${BUILD_SRC_BASE}" \
          BUILD_SRC_PASS="${BUILD_SRC_PASS}" \
          EXTRACT_BUILD_TARBALLS="true" \
          bash -euo pipefail scripts/fetch_build.sh
        '''
      }
    }

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
            SERVER_FILE="server_pci_map.txt" \
            REQ_WAIT_SECS="360" \
            RETRY_COUNT="3" \
          bash -euo pipefail scripts/cluster_reset.sh
        '''
      }
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
            INSTALL_SERVER_FILE="server_pci_map.txt" \
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
