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
      when { expression { return params.FETCH_BUILD } }  // run only if enabled
      steps {
        sh '''
          set -euo pipefail
          chmod +x scripts/fetch_build.sh
    
          # Pass inputs expected by fetch_build.sh
          NEW_VERSION="${NEW_VERSION}" \
          NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
          BUILD_SRC_HOST="${BUILD_SRC_HOST}" \
          BUILD_SRC_USER="${BUILD_SRC_USER}" \
          BUILD_SRC_BASE="${BUILD_SRC_BASE}" \
          SSH_KEY="${SSH_KEY}" \
          EXTRACT_BUILD_TARBALLS="true" \
          REQUIRE_BIN_REL="false" \
          scripts/fetch_build.sh
        '''
      }
    }


    // (cluster_reset & cluster_install stages unchanged)
  }
}
