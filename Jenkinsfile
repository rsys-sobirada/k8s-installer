pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    SERVER_FILE = 'server_pci_map.txt'
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key' // used for target servers
    K8S_VER     = '1.31.4'
    EXTRACT_BUILD_TARBALLS = 'true'
  }

  parameters {
    // Main flow
    string(name: 'NEW_VERSION',    defaultValue: '6.3.0_EA2',  description: 'Target bundle (may have suffix, e.g., 6.3.0_EA2)')
    string(name: 'OLD_VERSION',    defaultValue: '6.3.0_EA1',  description: 'Existing bundle (used if CLUSTER_RESET=true)')
    booleanParam(name: 'CLUSTER_RESET', defaultValue: true,    description: 'Run cluster reset first')
    string(name: 'OLD_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir of OLD_VERSION (for reset)')
    string(name: 'NEW_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir to place NEW_VERSION (and extract)')

    // Remote fetch (copy directly to CN servers)
    booleanParam(name: 'FETCH_BUILD', defaultValue: true, description: 'Fetch NEW_VERSION from build host to CN servers')
    string(name: 'BUILD_SRC_HOST', defaultValue: '172.26.2.96',     description: 'Build repo host')
    string(name: 'BUILD_SRC_USER', defaultValue: 'labadmin',         description: 'Build repo user')
    string(name: 'BUILD_SRC_BASE', defaultValue: '/CNBuild/6.3.0_EA2', description: 'Path on build host containing the tar.gz files')
    // Credentials IDs must exist in Jenkins
    // - build-src-creds: Username/Password for build host
    // - cn-ssh-key: SSH key for CN servers
  }

  stages {
    stage('Checkout') { steps { checkout scm } }

    stage('Fetch build to CN servers (optional)') {
      when { expression { return params.FETCH_BUILD } }
      steps {
        withCredentials([
          usernamePassword(credentialsId: 'build-src-creds', usernameVariable: 'BUILD_SRC_USER', passwordVariable: 'BUILD_SRC_PASS'),
          sshUserPrivateKey(credentialsId: 'cn-ssh-key', keyFileVariable: 'CN_KEY', usernameVariable: 'CN_USER')
        ]) {
          sh '''
            set -euo pipefail

            # Normalize line endings / BOM so bash parses cleanly
            sed -i 's/\\r$//' scripts/fetch_build_remote.sh || true
            perl -i -pe 'BEGIN{binmode(STDIN);binmode(STDOUT)} s/^\\x{FEFF}// if $.==1' scripts/fetch_build_remote.sh || true

            chmod +x scripts/fetch_build_remote.sh

            # If using password auth for build source, ensure sshpass exists
            if [ -n "${BUILD_SRC_PASS:-}" ]; then
              if ! command -v sshpass >/dev/null 2>&1; then
                echo "ERROR: sshpass is required on this Jenkins agent for password-based SCP/SSH to BUILD_SRC_HOST." >&2
                exit 2
              fi
            fi

            echo "Targets from ${SERVER_FILE}:"
            awk 'NF && $1 !~ /^#/' "${SERVER_FILE}" || true

            # Run the remote fetch with bash explicitly
            NEW_VERSION="${NEW_VERSION}" \
            NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
            SERVER_FILE="${SERVER_FILE}" \
            BUILD_SRC_HOST="${BUILD_SRC_HOST}" \
            BUILD_SRC_USER="${BUILD_SRC_USER}" \
            BUILD_SRC_BASE="${BUILD_SRC_BASE}" \
            BUILD_SRC_PASS="${BUILD_SRC_PASS}" \
            CN_USER="${CN_USER}" \
            CN_KEY="${CN_KEY}" \
            EXTRACT_BUILD_TARBALLS="${EXTRACT_BUILD_TARBALLS}" \
            bash -euo pipefail scripts/fetch_build_remote.sh
          '''
        }
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
            SERVER_FILE="${SERVER_FILE}" \
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
