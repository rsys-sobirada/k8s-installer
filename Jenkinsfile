pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    SERVER_FILE = 'server_pci_map.txt'
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key' // still used for target hosts, not for remote build fetch when password provided
    K8S_VER     = '1.31.4'
  }

  parameters {
    // install/upgrade flow
    string(name: 'NEW_VERSION',    defaultValue: '6.3.0_EA2',  description: 'Target bundle (may have suffix, e.g., 6.3.0_EA2)')
    string(name: 'OLD_VERSION',    defaultValue: '6.3.0_EA1',  description: 'Existing bundle (used if CLUSTER_RESET=true)')
    booleanParam(name: 'CLUSTER_RESET', defaultValue: true,    description: 'Run cluster reset first')
    string(name: 'OLD_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir of OLD_VERSION (for reset)')
    string(name: 'NEW_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base dir to place NEW_VERSION (and extract)')

    // optional remote fetch (password-based)
    booleanParam(name: 'FETCH_BUILD', defaultValue: false, description: 'Fetch NEW_VERSION from a remote host before install')
    string(name: 'BUILD_SRC_HOST', defaultValue: '',               description: 'Remote host (required if FETCH_BUILD=true)')
    string(name: 'BUILD_SRC_USER', defaultValue: 'labadmin',       description: 'Remote user')
    string(name: 'BUILD_SRC_BASE', defaultValue: '/repo/builds',   description: 'Remote path containing the tar.gz files')
    password(name: 'BUILD_SRC_PASS', defaultValue: '', description: 'Remote user password (required if FETCH_BUILD=true)')
  }

  stages {
    stage('Checkout') { steps { checkout scm } }

    stage('Fetch build (optional)') {
      when { allOf { expression { return params.FETCH_BUILD }
                     expression { return params.BUILD_SRC_HOST?.trim() }
                     expression { return params.BUILD_SRC_PASS?.trim() } } }
      steps {
        sh '''
          set -e
          # ensure sshpass exists if we’re going to use password auth
          if ! command -v sshpass >/dev/null 2>&1 ; then
            echo "ERROR: sshpass is required for password-based scp. Install it on the Jenkins agent." >&2
            exit 2
          fi

          chmod +x scripts/fetch_build.sh
          NEW_VERSION="${NEW_VERSION}" \
          NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
          BUILD_SRC_HOST="${BUILD_SRC_HOST}" \
          BUILD_SRC_USER="${BUILD_SRC_USER}" \
          BUILD_SRC_BASE="${BUILD_SRC_BASE}" \
          BUILD_SRC_PASS="${BUILD_SRC_PASS}" \
          EXTRACT_BUILD_TARBALLS="true" \
          scripts/fetch_build.sh
        '''
      }
    }

    // Your existing reset + install stages go here unchanged
    // - stage('Cluster reset (optional)') -> scripts/cluster_reset.sh
    // - stage('Cluster install')         -> scripts/cluster_install.sh
  }
}
