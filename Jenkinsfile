pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    // ansiColor fallback for older plugins
    wrap([$class: 'AnsiColorBuildWrapper', colorMapName: 'xterm'])
  }

  parameters {
    // --- Core ---
    string(name: 'NEW_VERSION',     defaultValue: '6.3.0_EA2',  description: 'Target CN/K8s bundle to install')
    string(name: 'OLD_VERSION',     defaultValue: '6.3.0_EA1',  description: 'Existing bundle (used only if CLUSTER_RESET=true)')
    booleanParam(name: 'CLUSTER_RESET', defaultValue: true,     description: 'Run scripts/cluster_reset.sh before install')
    string(name: 'OLD_BUILD_PATH',  defaultValue: '/home/labadmin', description: 'Base dir that contains OLD_VERSION (for reset)')
    string(name: 'NEW_BUILD_PATH',  defaultValue: '/home/labadmin', description: 'Base dir that contains NEW_VERSION (for install)')
    string(name: 'SERVER_FILE',     defaultValue: 'server_pci_map.txt', description: 'name:ip[:custom_k8s_base] list in repo root')
    string(name: 'SSH_KEY',         defaultValue: '/var/lib/jenkins/.ssh/jenkins_key', description: 'SSH key to reach target servers')
    string(name: 'K8S_VER',         defaultValue: '1.31.4',     description: 'Kubespray dir suffix (k8s-v<ver>)')

    // --- Optional fetch of the new build from a remote host ---
    booleanParam(name: 'FETCH_BUILD', defaultValue: false,
                 description: 'Copy NEW_VERSION from a remote host to NEW_BUILD_PATH before install')
    choice(name: 'BUILD_TRANSFER_MODE', choices: ['scp', 'rsync'],
           description: 'Used only when FETCH_BUILD=true')
    string(name: 'BUILD_SRC_HOST',     defaultValue: '',          description: 'Remote host (only if FETCH_BUILD=true)')
    string(name: 'BUILD_SRC_USER',     defaultValue: 'labadmin',  description: 'Remote user (only if FETCH_BUILD=true)')
    string(name: 'BUILD_SRC_BASE',     defaultValue: '/repo/builds', description: 'Remote base dir containing NEW_VERSION/')
    string(name: 'BUILD_SSH_KEY_PATH', defaultValue: '/var/lib/jenkins/.ssh/jenkins_key',
           description: 'SSH key for the remote build host')
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        sh 'git rev-parse --short HEAD || true'
      }
    }

    stage('Fetch build (optional)') {
      when { expression { return params.FETCH_BUILD } }
      steps {
        sh '''
          set -euo pipefail
          echo "[Fetch] ${BUILD_TRANSFER_MODE} from ${BUILD_SRC_USER}@${BUILD_SRC_HOST}:${BUILD_SRC_BASE}/${NEW_VERSION} -> ${NEW_BUILD_PATH}/${NEW_VERSION}"

          if [ -z "${BUILD_SRC_HOST}" ]; then
            echo "ERROR: BUILD_SRC_HOST is empty but FETCH_BUILD=true"; exit 2
          fi

          mkdir -p "${NEW_BUILD_PATH}/${NEW_VERSION}"

          if [ "${BUILD_TRANSFER_MODE}" = "scp" ]; then
            ssh -o StrictHostKeyChecking=no -i "${BUILD_SSH_KEY_PATH}" \
                "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" "test -d '${BUILD_SRC_BASE}/${NEW_VERSION}'"
            scp -o StrictHostKeyChecking=no -i "${BUILD_SSH_KEY_PATH}" -r \
                "${BUILD_SRC_USER}@${BUILD_SRC_HOST}:${BUILD_SRC_BASE}/${NEW_VERSION}/" \
                "${NEW_BUILD_PATH}/${NEW_VERSION}/"
          else
            rsync -az --delete -e "ssh -o StrictHostKeyChecking=no -i ${BUILD_SSH_KEY_PATH}" \
                "${BUILD_SRC_USER}@${BUILD_SRC_HOST}:${BUILD_SRC_BASE}/${NEW_VERSION}/" \
                "${NEW_BUILD_PATH}/${NEW_VERSION}/"
          fi
        '''
      }
    }

    stage('Cluster reset (optional)') {
      when { expression { return params.CLUSTER_RESET } }
      steps {
        sh '''
          set -euo pipefail
          chmod +x scripts/cluster_reset.sh
          RESET_YML_WS="${WORKSPACE}/reset.yml" \
          SSH_KEY="${SSH_KEY}" \
          SERVER_FILE="${SERVER_FILE}" \
          OLD_VERSION="${OLD_VERSION}" \
          OLD_BUILD_PATH="${OLD_BUILD_PATH}" \
          K8S_VER="${K8S_VER}" \
          scripts/cluster_reset.sh
        '''
      }
    }

    stage('Cluster install') {
      steps {
        sh '''
          set -euo pipefail
          chmod +x scripts/cluster_install.sh
          NEW_VERSION="${NEW_VERSION}" \
          NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
          SSH_KEY="${SSH_KEY}" \
          SERVER_FILE="${SERVER_FILE}" \
          K8S_VER="${K8S_VER}" \
          scripts/cluster_install.sh
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
