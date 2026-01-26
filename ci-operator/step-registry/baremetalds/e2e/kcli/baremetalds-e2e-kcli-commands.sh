#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds e2e kcli setup command ************"

# Source required variables for SSH access to hypervisor
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "sleep for 3h"
sleep 3h

# Install kcli
echo "Install kcli on the test container"
curl -s https://raw.githubusercontent.com/karmab/kcli/main/install.sh | bash

ssh_key="${CLUSTER_PROFILE_DIR}/packet-ssh-key"
server_ip="${IP}"

mkdir -p ~/.ssh
mkdir -p ~/.kcli

cat >> ~/.ssh/config <<EOF
Host hypervisor
    HostName ${server_ip}
    User root
    ServerAliveInterval 120
    IdentityFile ${ssh_key}
EOF

cat >> ~/.kcli/config.yml <<EOF
twix:
  host: hypervisor
  pool: default
  protocol: ssh
  type: kvm
  user: root
EOF

echo "Connect kcli with remote hypervisor"
kcli switch host twix

echo "Ensuring clean state for VM creation"
kcli delete vm ovn-kubernetes-e2e -y 2>/dev/null || true

echo "Creating test VM with Docker"
kcli create vm -i fedora42 ovn-kubernetes-e2e --wait -P "cmds=['dnf install -y docker','systemctl enable --now docker']"

echo "Verifying Docker installation in VM"
if ! kcli ssh ovn-kubernetes-e2e -- sudo docker version; then
  echo "ERROR: Docker installation failed in VM"
  exit 1
fi

echo "kcli setup and VM creation completed"
