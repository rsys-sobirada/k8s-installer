#!/usr/bin/env bash
set -euo pipefail

: "${INSTALL_IP_ADDR:?must be set (e.g. 10.10.10.20/24)}"

# Extract IP (strip /CIDR)
IP="${INSTALL_IP_ADDR%%/*}"

ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa
ssh-copy-id root@"${IP}"
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
ssh-keygen -f "/root/.ssh/known_hosts" -R "${IP}"
systemctl restart sshd
