#!/bin/bash
set -e

# Trap to clean up virtual environment if active
trap '[ -n "$VIRTUAL_ENV" ] && type deactivate &>/dev/null && deactivate' EXIT

print_error() {
    echo -e "\e[1;31m[ERROR] $1\e[0m"
}

check_internet() {
    echo -e "\e[1;34m[INFO] Checking internet connectivity...\e[0m"

    # Check general internet connectivity using HTTP instead of ping
    if ! wget -q --spider --timeout=5 http://google.com; then
        echo -e "\e[1;31m[ERROR] No internet connection. Please check your network.\e[0m"
        exit 1
    fi
}

install_prerequisites() {
    echo -e "\e[1;31mCHECKING PYTHON INSTALLATION\e[0m\n"

    if ! command -v python3.12 &> /dev/null; then
        print_error "Python 3.12 not found. Installing..."
        sudo add-apt-repository ppa:deadsnakes/ppa -y
        sudo apt update
        sudo apt install python3.12 -y
    fi

    echo -e "\e[1;31mINSTALLING ADDITIONAL PACKAGES\e[0m\n"
    sudo apt-get install -y jq wget unzip python3-paramiko

    if ! command -v pip3 &> /dev/null; then
        sudo apt-get -y install python3-pip
    fi
}

setup_python_venv() {
    echo -e "\e[1;34m[INFO] Setting up Python Virtual Environment...\e[0m"

    # Install venv package if not already installed
    if ! dpkg -s python3.12-venv &>/dev/null; then
        sudo apt update
        sudo apt install python3.12-venv -y
    fi

    # Create venv if it doesn't exist
    if [[ ! -d "myenv" ]]; then
        python3.12 -m venv myenv
    fi

    # Activate venv
    source myenv/bin/activate

    # Install required Python packages (including Ansible)
    pip install shyaml jsonschema termcolor scp PyYAML ansible
}

install_kubespray_prerequisites() {
    echo -e "\e[1;31mINSTALLING KUBESPRAY PREREQUISITES\e[0m\n"
    pip install -r kubespray-2.27.0/requirements.txt
}

# MAIN EXECUTION STARTS HERE
check_internet
install_prerequisites
setup_python_venv
install_kubespray_prerequisites

echo -e "\e[1;31m[STEP] STARTING K8S AND 5GCN UNINSTALLATION\e[0m"

# Check for ansible-playbook after virtual environment is active
if ! command -v ansible-playbook &>/dev/null; then
    print_error "ansible-playbook not found! Make sure Ansible is installed properly."
    exit 1
fi

cd kubespray-2.27.0
ansible-playbook -i inventory/sample/hosts.yaml reset.yml -b \
  -e "skip_confirmation=true reset_confirmation=true"

echo -e "\e[1;32m[SUCCESS] K8S AND 5GCN UNINSTALLED SUCCESSFULLY\e[0m"

cd ../ && rm -rf kubespray-2.27.0 v2.27.0.zip
rm -rf myenv  # Still removing virtual env folder itself
