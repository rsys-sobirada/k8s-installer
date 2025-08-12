pipeline {
  agent any

  parameters {
    // --- Versions & paths ---
    string(name: 'NEW_VERSION',  defaultValue: '6.3.0_EA2',     description: 'Target CN/K8s bundle version to install')
    string(name: 'NEW_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base directory that contains NEW_VERSION on targets')
    string(name: 'OLD_VERSION',  defaultValue: '6.3.0_EA1',     description: 'Existing version currently on servers (for reset)')
    string(name: 'OLD_BUILD_PATH', defaultValue: '/home/labadmin', description: 'Base directory that contains OLD_VERSION on targets')
    booleanParam(name: 'CLUSTER_RESET', defaultValue: true, description: 'Reset cluster before install')
    string(name: 'K8S_VER', defaultValue: '1.31.4', description: 'Kubernetes version directory (k8s-v<ver>)')
    string(name: 'KSPRAY_DIR', defaultValue: 'kubespray-2.27.0', description: 'Kubespray dir name under the version path')

    // --- Optional: fetch new build from a remote server (Active Choices) ---
    booleanParam(name: 'FETCH_BUILD', defaultValue: false,
      description: 'Fetch NEW build from a remote server before install')

    // Info panel that reacts to FETCH_BUILD
    [$class: 'DynamicReferenceParameter',
      name: 'BUILD_COPY_SECTION',
      referencedParameters: 'FETCH_BUILD',
      script: [$class: 'GroovyScript', script: [sandbox: true, script: '''
if (FETCH_BUILD.toBoolean()) {
  return "<div style=\\"margin:6px 0;padding:8px;border:1px solid #ccd;background:#f6f9ff\\"><b>Remote build copy is ENABLED.</b> Fill details below.</div>"
}
return "<span style=\\"color:#888\\">Remote build copy is disabled.</span>"
''']]]

    // Reactive inputs (only used when FETCH_BUILD=true)
    [$class: 'CascadeChoiceParameter', name: 'BUILD_SRC_HOST',
      description: 'Remote build server hostname/IP',
      referencedParameters: 'FETCH_BUILD', choiceType: 'PT_TEXTBOX',
      script: [$class: 'GroovyScript', script: [sandbox: true, script: 'return ""']]]

    [$class: 'CascadeChoiceParameter', name: 'BUILD_SRC_USER',
      description: 'SSH user on the build server',
      referencedParameters: 'FETCH_BUILD', choiceType: 'PT_TEXTBOX',
      script: [$class: 'GroovyScript', script: [sandbox: true, script: 'return "labadmin"']]]

    [$class: 'CascadeChoiceParameter', name: 'BUILD_SRC_BASE',
      description: 'Base path on the build server; versioned path is derived from NEW_VERSION',
      referencedParameters: 'FETCH_BUILD', choiceType: 'PT_TEXTBOX',
      script: [$class: 'GroovyScript', script: [sandbox: true, script: 'return "/home/labadmin"']]]

    [$class: 'CascadeChoiceParameter', name: 'BUILD_SSH_KEY_PATH',
      description: 'SSH private key path for the build server',
      referencedParameters: 'FETCH_BUILD', choiceType: 'PT_TEXTBOX',
      script: [$class: 'GroovyScript', script: [sandbox: true, script: 'return "/var/lib/jenkins/.ssh/jenkins_key"']]]

    [$class: 'CascadeChoiceParameter', name: 'BUILD_TRANSFER_MODE',
      description: 'Copy mode',
      referencedParameters: 'FETCH_BUILD', choiceType: 'PT_SINGLE_SELECT',
      script: [$class: 'GroovyScript', script: [sandbox: true, script: '''
return FETCH_BUILD.toBoolean() ? ["stage-then-push (recommended)"] : ["(disabled)"]
''']]]
  }

  stages {
    stage('Reset → Install') {
      steps {
        script {
          // Optional validation when fetch is enabled
          if (params.FETCH_BUILD && !params.BUILD_SRC_HOST?.trim()) {
            error "BUILD_SRC_HOST is required when FETCH_BUILD=true"
          }

          sh """
            set -e
            env \
              # reset controls
              CLUSTER_RESET="${params.CLUSTER_RESET}" \
              OLD_VERSION="${params.OLD_VERSION}" \
              OLD_BUILD_PATH="${params.OLD_BUILD_PATH}" \
              K8S_VER="${params.K8S_VER}" \
              KSPRAY_DIR="${params.KSPRAY_DIR}" \
              RESET_YML_WS="\$WORKSPACE/reset.yml" \
              SSH_KEY="/var/lib/jenkins/.ssh/jenkins_key" \
              SERVER_FILE="server_pci_map.txt" \
              REQ_WAIT_SECS="360" \
              RETRY_COUNT="3" \
              # install controls
              NEW_VERSION="${params.NEW_VERSION}" \
              NEW_BUILD_PATH="${params.NEW_BUILD_PATH}" \
              INSTALL_SERVER_FILE="server_pci_map.txt" \
              INSTALL_IP_ADDR="10.10.10.20/24" \
              INSTALL_IP_IFACE="" \
              # optional remote build fetch
              FETCH_BUILD="${params.FETCH_BUILD}" \
              BUILD_SRC_HOST="${params.BUILD_SRC_HOST}" \
              BUILD_SRC_USER="${params.BUILD_SRC_USER}" \
              BUILD_SRC_BASE="${params.BUILD_SRC_BASE}" \
              BUILD_SSH_KEY_PATH="${params.BUILD_SSH_KEY_PATH}" \
              BUILD_TRANSFER_MODE="${params.BUILD_TRANSFER_MODE}" \
            bash scripts/run_upgrade_chain.sh
          """
        }
      }
    }
  }
}
