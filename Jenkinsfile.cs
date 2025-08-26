// Jenkinsfile.cs — run ONLY CS config & install

pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    SERVER_FILE = 'server_pci_map.txt'                 // adjust if needed
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key'  // adjust if needed
    CS_SCRIPT   = 'scripts/cs_config.sh'
  }

  parameters {
    // CS inputs
    string(name: 'NEW_BUILD_PATH', defaultValue: '/home/labadmin/6.3.0/EA3',
           description: 'Base path that contains TRILLIUM_5GCN_CNF_REL_<VER>/...')
    string(name: 'NEW_VERSION',    defaultValue: '6.3.0_EA3',
           description: 'Script uses only the part before "_" (e.g., 6.3.0)')
    choice(name: 'DEPLOYMENT_TYPE', choices: ['Low','Medium','High'],
           description: 'If Low → capacitySetup set to "LOW"; Medium/High unchanged')
    string(name: 'HOST_USER',      defaultValue: 'root', description: 'SSH user on CN hosts')
    string(name: 'CS_STAGE_TIMEOUT_MIN', defaultValue: '60', description: 'Timeout (minutes)')
  }

  stages {
    stage('Checkout') { steps { checkout scm } }

    stage('CS config & install') {
      steps {
        script {
          def csTimeout = params.CS_STAGE_TIMEOUT_MIN as Integer
          timeout(time: csTimeout, unit: 'MINUTES') {
            withEnv([
              "NEW_BUILD_PATH=${params.NEW_BUILD_PATH}",
              "NEW_VERSION=${params.NEW_VERSION}",
              "DEPLOYMENT_TYPE=${params.DEPLOYMENT_TYPE}",
              "HOST_USER=${params.HOST_USER}"
            ]) {
              sh '''#!/usr/bin/env bash
set -euo pipefail
: "${SERVER_FILE:=server_pci_map.txt}"
: "${SSH_KEY:=/var/lib/jenkins/.ssh/jenkins_key}"
: "${CS_SCRIPT:=scripts/cs_config.sh}"

# Safe defaults so first run / Replay can't fail on unset vars
: "${NEW_BUILD_PATH:=/home/labadmin/6.3.0/EA3}"
: "${NEW_VERSION:=6.3.0_EA3}"
: "${DEPLOYMENT_TYPE:=Medium}"
: "${HOST_USER:=root}"

echo "[pipeline] (CS) NEW_BUILD_PATH=${NEW_BUILD_PATH}"
echo "[pipeline] (CS) NEW_VERSION=${NEW_VERSION}"
echo "[pipeline] (CS) DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE}"
echo "[pipeline] (CS) HOST_USER=${HOST_USER}"

test -f "${CS_SCRIPT}" || { echo "CS script not found at ${CS_SCRIPT}"; exit 2; }
sed -i 's/\\r$//' "${CS_SCRIPT}" || true
chmod +x "${CS_SCRIPT}"

set -o pipefail
env \
  SERVER_FILE="${SERVER_FILE}" \
  SSH_KEY="${SSH_KEY}" \
  NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
  NEW_VERSION="${NEW_VERSION}" \
  DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE}" \
  HOST_USER="${HOST_USER}" \
bash -euo pipefail "${CS_SCRIPT}" |& tee cs_config.log
'''
            }
          }
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'cs_config.log', allowEmptyArchive: true
    }
  }
}
