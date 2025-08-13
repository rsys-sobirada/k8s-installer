pipeline {
  agent any
  options {
    timestamps()
    ansiColor('xterm')
    disableConcurrentBuilds()
  }

  parameters {
    // ── Core inputs ───────────────────────────────────────────
    string(name: 'NEW_VERSION',     defaultValue: '6.3.0_EA2',  description: 'Target CN/K8s bundle to install')
    string(name: 'OLD_VERSION',     defaultValue: '6.3.0_EA1',  description: 'Existing bundle (used only if CLUSTER_RESET=true)')
    booleanParam(name: 'CLUSTER_RESET', defaultValue: true,     description: 'Run scripts/cluster_reset.sh before install')
    string(name: 'OLD_BUILD_PATH',  defaultValue: '/home/labadmin', description: 'Base dir on target servers that contains OLD_VERSION')
    string(name: 'NEW_BUILD_PATH',  defaultValue: '/home/labadmin', description: 'Base dir on target servers that contains NEW_VERSION')
    string(name: 'SERVER_FILE',     defaultValue: 'server_pci_map.txt', description: 'name:ip[:custom_k8s_base] list in repo root')
    string(name: 'SSH_KEY',         defaultValue: '/var/lib/jenkins/.ssh/jenkins_key', description: 'SSH key used to reach target servers')
    string(name: 'K8S_VER',         defaultValue: '1.31.4',     description: 'Kubespray k8s version directory suffix (k8s-v<ver>)')

    // ── Optional: fetch build from a remote host ──────────────
    booleanParam(name: 'FETCH_BUILD', defaultValue: false,
                 description: 'Copy the build from a remote host to NEW_BUILD_PATH before install')
    activeChoiceReactiveParam(name: 'BUILD_TRANSFER_MODE') {
      description('Only used when FETCH_BUILD=true')
      choiceType('SINGLE_SELECT')
      groovyScript {
        script('return FETCH_BUILD.toBoolean() ? ["scp","rsync"] : ["(disabled)"]')
        fallbackScript('return ["scp"]')
      }
      referencedParameter('FETCH_BUILD')
    }
    string(name: 'BUILD_SRC_HOST',      defaultValue: '',          description: 'Remote host (ignored if FETCH_BUILD=false)')
    string(name: 'BUILD_SRC_USER',      defaultValue: 'labadmin',  description: 'Remote user (ignored if FETCH_BUILD=false)')
    string(name: 'BUILD_SRC_BASE',      defaultValue: '/repo/builds', description: 'Remote base dir that contains NEW_VERSION/')
    string(name: 'BUILD_SSH_KEY_PATH',  defaultValue: '/var/lib/jenkins/.ssh/jenkins_key', description: 'SSH key for remote build host')
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
          if [ "${BUILD_TRANSFER_MODE}" = "scp" ]; then
            ssh -o StrictHostKeyChecking=no -i "${BUILD_SSH_KEY_PATH}" \
                "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" "test -d '${BUILD_SRC_BASE}/${NEW_VERSION}'"
            mkdir -p "${NEW_BUILD_PATH}/${NEW_VERSION}"
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
}
