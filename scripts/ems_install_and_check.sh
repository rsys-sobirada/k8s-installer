stage('EMS install & health check (remote via SSH)') {
  steps {
    sh '''
      set -e
      chmod +x scripts/ems_install_and_check.sh
      # NOTE: NEW_BUILD_PATH should include the tag folder (e.g., /home/labadmin/EA3),
      # matching the layout your nf_config.sh expects.
      SERVER_FILE="server_pci_map.txt" \
      SSH_KEY="/var/lib/jenkins/.ssh/jenkins_key" \
      NEW_BUILD_PATH="/home/labadmin/EA3" \
      NEW_VERSION="6.3.0_EA3" \
      HOST_USER="root" \
      # HOST_NAME="node1" \   # optional: pick a specific entry
      scripts/ems_install_and_check.sh
    '''
  }
}
