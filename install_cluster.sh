#!/bin/bash

SERVER="$1"
PCI="$2"

echo "🔧 Installing Kubernetes on $SERVER with PCI $PCI"

ssh -o StrictHostKeyChecking=no user@$SERVER <<EOF2
echo "✅ Connected to \$HOSTNAME"
echo "🔌 Using PCI address: $PCI"

# Disable swap
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Install Docker
sudo apt-get update
sudo apt-get install -y docker.io
sudo systemctl enable docker
sudo systemctl start docker

# Install Kubernetes components
sudo apt-get install -y apt-transport-https curl
sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "✅ Kubernetes installation completed on $SERVER"
EOF2
