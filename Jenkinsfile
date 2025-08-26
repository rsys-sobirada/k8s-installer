// Jenkinsfile (health-check only)

pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  // Keep these minimal envs the health script needs
  environment {
    SERVER_FILE = 'server_pci_map.txt'
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key'
  }

  // Optional knobs to tune the script without editing it
  parameters {
    string(name: 'HEALTH_RETRY_WAIT_SECS', defaultValue: '15', description: 'Seconds to wait before retrying')
    string(name: 'HEALTH_RETRIES',          defaultValue: '1',   description: 'Number of retries (0 = no retry)')
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('K8s health check') {
      steps {
        timeout(time: 20, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

# Make sure the script is executable and unix-formatted
sed -i 's/\\r$//' scripts/k8s_health_check.sh || true
chmod +x scripts/k8s_health_check.sh

# Run the health check; exit codes are passed through
env \
  SERVER_FILE="${SERVER_FILE}" \
  SSH_KEY="${SSH_KEY}" \
  HEALTH_RETRY_WAIT_SECS="${HEALTH_RETRY_WAIT_SECS}" \
  HEALTH_RETRIES="${HEALTH_RETRIES}" \
bash -euo pipefail scripts/k8s_health_check.sh
'''
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: '**/*.log', allowEmptyArchive: true
    }
  }
}
