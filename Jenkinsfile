pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    SERVER_FILE = 'server_pci_map.txt'
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key'   // used for target servers AND remote build host
    K8S_VER     = '1.31.4'
  }

  parameters {
    string(name: 'NEW_VERSION',    defaultValue: '6.3.0_EA2',  description: 'Target CN/K8s bundle to install')
    string(name: 'OLD_VERSION',    defaultValue: '6.3.0_EA1',  description: 'Existing bundle (used if CLUSTER_RESET=true)')
    booleanParam(name: 'CLUSTER_RESET', defaultValue: true,    description: 'Run cluster reset first')
    string(name: 'OLD_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir of OLD_VERSION (for reset)')
    string(name: 'NEW_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir of NEW_VERSION (for install)')

    // optional remote fetch (no password; uses SSH_KEY)
    booleanParam(name: 'FETCH_BUILD', defaultValue: false, description: 'Fetch NEW_VERSION from remote host before install')
    choice(name: 'BUILD_TRANSFER_MODE', choices: ['scp', 'rsync'], description: 'Used only when FETCH_BUILD=true')
    string(name: 'BUILD_SRC_HOST', defaultValue: '', description: 'Remote host (only if FETCH_BUILD=true)')
    string(name: 'BUILD_SRC_USER', defaultValue: 'labadmin', description: 'Remote user')
    string(name: 'BUILD_SRC_BASE', defaultValue: '/repo/builds', description: 'Remote base dir containing NEW_VERSION/')
  }

  stages {
    stage('Checkout') { steps { checkout scm } }

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

          SSH_OPTS='-o StrictHostKeyChecking=no -i '"${SSH_KEY}"

          if [ "${BUILD_TRANSFER_MODE}" = "scp" ]; then
            ssh ${SSH_OPTS} "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" "test -d '${BUILD_SRC_BASE}/${NEW_VERSION}'"
            scp ${SSH_OPTS} -r \
              "${BUILD_SRC_USER}@${BUILD_SRC_HOST}:${BUILD_SRC_BASE}/${NEW_VERSION}/" \
              "${NEW_BUILD_PATH}/${NEW_VERSION}/"
          else
            rsync -az --delete -e "ssh ${SSH_OPTS}" \
              "${BUILD_SRC_USER}@${BUILD_SRC_HOST}:${BUILD_SRC_BASE}/${NEW_VERSION}/" \
              "${NEW_BUILD_PATH}/${NEW_VERSION}/"
          fi
        '''
      }
    }

    // (cluster_reset & cluster_install stages unchanged)
  }
}
