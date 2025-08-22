#!/usr/bin/env bash
set -euo pipefail

: "${INSTALL_IP_ADDR:?must be set (e.g. 10.10.10.20/24)}"
: "${CN_BOOTSTRAP_PASS:?must be set}"

# Extract plain IP (strip /mask if present)
IP="${INSTALL_IP_ADDR%%/*}"

ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa
sshpass -p "${CN_BOOTSTRAP_PASS}" ssh-copy-id -o StrictHostKeyChecking=no root@"${IP}"
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
ssh-keygen -f "/root/.ssh/known_hosts" -R "${IP}"
systemctl restart sshd
