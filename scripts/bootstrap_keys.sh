#!/usr/bin/env bash
set -euo pipefail

: "${INSTALL_IP_ADDR:?INSTALL_IP_ADDR must be set (e.g. 10.10.10.20/24)}"
: "${CN_BOOTSTRAP_PASS:?CN_BOOTSTRAP_PASS must be set}"

IP="$(echo "${INSTALL_IP_ADDR}" | awk -F/ '{print $1}')"

# exact lines you requested, with password via sshpass and IP from INSTALL_IP_ADDR
ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa
sshpass -p "${CN_BOOTSTRAP_PASS}" ssh-copy-id -o StrictHostKeyChecking=no root@"${IP}"
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
ssh-keygen -f "/root/.ssh/known_hosts" -R "${IP}"
systemctl restart sshd
