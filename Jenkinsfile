pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  /************ fixed knobs (not shown to users) ************/
  environment {
    SERVER_FILE    = 'server_pci_map.txt'                 // name:ip[:custom_path] list in repo root
    SSH_KEY        = '/var/lib/jenkins/.ssh/jenkins_key'  // used for targets & remote build host
    K8S_VER        = '1.31.4'
    KSPRAY_DIR     = 'kubespray-2.27.0'
    RESET_YML_WS   = "${WORKSPACE}/reset.yml"
    REQ_WAIT_SECS  = '360'
    RETRY_COUNT    = '3'
    INSTALL_IP_ADDR  = '10.10.10.20/24' // must exist on node; iface may be down
    INSTALL_IP_IFACE = ''               // leave blank to auto-pick
  }

  /************ user inputs (GUI) ************/
  parameters {
    string( name: 'NEW_VERSION', defaultValue: '6.3.0_EA2',
            description: 'Target bundle to install (suffix ok; fetch script strips to base 6.3.0).' )
    string( name: 'OLD_VERSION', defaultValue: '6.3.0_EA1',
            description: 'Existing bundle on servers (used only if CLUSTER_RESET=true).' )
    booleanParam( name: 'CLUSTER_RESET', defaultValue: true,
                  description: 'Run cluster reset before installing.' )

    string( name: 'OLD_BUILD_PATH', defaultValue: '/home/labadmin',
            description: 'Base directory that contains OLD_VERSION (for reset).' )
    string( name: 'NEW_BUILD_PATH', defaultValue: '/home/labadmin',
            description: 'Base directory to hold NEW_VERSION (for install).' )

    // Optional remote fetch of the NEW_VERSION build
    booleanParam( name: 'FETCH_BUILD', defaultValue: false,
                  description: 'Fetch NEW_VERSION from a remote host into NEW_BUILD_PATH before install.' )
    choice( name: 'BUILD_TRANSFER_MODE', choices: ['scp','rsync'],
            description: 'Used only when FETCH_BUILD=true.' )
    string( name: 'BUILD_SRC_HOST', defaultValue: '',
            description: 'Remote host (only if FETCH_BUILD=true).' )
    string( name: 'BUILD_SRC_USER', defaultValue: 'labadmin',
            description: 'Remote user (only if FETCH_BUILD=true).' )
    string( name: 'BUILD_SRC_BASE', defaultValue: '/repo/builds',
            description: 'Remote base dir that contains NEW_VERSION/ (only if FETCH_BUILD=true).' )
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Fetch build (optional)') {
      when { expression { return params.FETCH_BUILD } }
      steps {
        sh '''
          set -e
          chmod +x scripts/fetch_build.sh
          # pass env safely; no stray spaces
          env \
            NEW_VERSION="${NEW_VERSION}" \
            NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
            BUILD_SRC_HOST="${BUILD_SRC_HOST}" \
            BUILD_SRC_USER="${BUILD_SRC_USER}" \
            BUILD_SRC_BASE="${BUILD_SRC_BASE}" \
            BUILD_TRANSFER_MODE="${BUILD_TRANSFER_MODE}" \
            SSH_KEY="${SSH_KEY}" \
            EXTRACT_BUILD_TARBALLS="true" \
            REQUIRE_BIN_REL="false" \
          bash scripts/fetch_build.sh
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
            CLUSTER_RESET="true" \
            OLD_VERSION="${OLD_VERSION}" \
            OLD_BUILD_PATH="${OLD_BUILD_PATH}" \
            K8S_VER="${K8S_VER}" \
            KSPRAY_DIR="${KSPRAY_DIR}" \
            RESET_YML_WS="${RESET_YML_WS}" \
            SSH_KEY="${SSH_KEY}" \
            SERVER_FILE="${SERVER_FILE}" \
            REQ_WAIT_SECS="${REQ_WAIT_SECS}" \
            RETRY_COUNT="${RETRY_COUNT}" \
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
            KSPRAY_DIR="${KSPRAY_DIR}" \
            INSTALL_SERVER_FILE="${SERVER_FILE}" \
            INSTALL_IP_ADDR="${INSTALL_IP_ADDR}" \
            INSTALL_IP_IFACE="${INSTALL_IP_IFACE}" \
            SSH_KEY="${SSH_KEY}" \
          bash -euo pipefail scripts/cluster_install.sh
        '''
      }
    }
  }

  post {
    always {
      // drop anything your scripts put under logs/ if you want
      archiveArtifacts artifacts: 'logs/**', allowEmptyArchive: true
    }
  }
}
