pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    // for your reset/install scripts (targets)
    SSH_KEY   = '/var/lib/jenkins/.ssh/jenkins_key'
    K8S_VER   = '1.31.4'
    // credential used ONLY to fetch builds from the remote build host
    BUILD_SRC_CRED = 'build_src_ssh'   // <-- create this in Jenkins Credentials
  }

  parameters {
    // install / reset knobs
    string(name: 'NEW_VERSION',    defaultValue: '6.3.0_EA2', description: 'Target bundle to install')
    string(name: 'OLD_VERSION',    defaultValue: '6.3.0_EA1', description: 'Current bundle on servers')
    booleanParam(name: 'CLUSTER_RESET', defaultValue: true,    description: 'Run cluster reset before install')
    string(name: 'OLD_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir of OLD_VERSION on targets')
    string(name: 'NEW_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir of NEW_VERSION on targets')

    // optional remote fetch (now fully credentialed via Jenkins)
    booleanParam(name: 'FETCH_BUILD', defaultValue: false, description: 'Fetch NEW_VERSION from remote host before install')
    string(name: 'BUILD_SRC_HOST', defaultValue: '',           description: 'Remote build host (e.g. 172.26.2.96)')
    string(name: 'BUILD_SRC_USER', defaultValue: 'sobirada',   description: 'Remote user on build host')
    string(name: 'BUILD_SRC_BASE', defaultValue: '/CNBuild/6.3.0_EA2',
           description: 'Remote directory that ALREADY contains the files (exact path; no suffix added)')
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Fetch build (optional)') {
      when { expression { return params.FETCH_BUILD } }
      steps {
        sshagent(credentials: [env.BUILD_SRC_CRED]) {
          sh '''
            set -e
            chmod +x scripts/fetch_build.sh
            echo ">>> Fetching build ${NEW_VERSION} from ${BUILD_SRC_USER}@${BUILD_SRC_HOST} : ${BUILD_SRC_BASE} -> ${NEW_BUILD_PATH}"
            NEW_VERSION="${NEW_VERSION}" \
            NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
            BUILD_SRC_HOST="${BUILD_SRC_HOST}" \
            BUILD_SRC_USER="${BUILD_SRC_USER}" \
            BUILD_SRC_BASE="${BUILD_SRC_BASE}" \
            EXTRACT_BUILD_TARBALLS="true" \
            REQUIRE_BIN_REL="false" \
            bash scripts/fetch_build.sh
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
            CLUSTER_RESET="${CLUSTER_RESET}" \
            OLD_VERSION="${OLD_VERSION}" \
            OLD_BUILD_PATH="${OLD_BUILD_PATH}" \
            K8S_VER="${K8S_VER}" \
            KSPRAY_DIR="kubespray-2.27.0" \
            RESET_YML_WS="$WORKSPACE/reset.yml" \
            SSH_KEY="${SSH_KEY}" \
            SERVER_FILE="server_pci_map.txt" \
            REQ_WAIT_SECS="360" \
            RETRY_COUNT="3" \
          bash scripts/cluster_reset.sh
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
          bash scripts/cluster_install.sh
        '''
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: '**/*.log, **/*.pid, **/install.log', allowEmptyArchive: true
    }
  }
}
