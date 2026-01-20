#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds e2e kcli setup command ************"

# Source required variables for SSH access to hypervisor
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "Installing kcli and creating test VM"
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -o nounset
set -o errexit
set -o pipefail

# Generate ssh keys which is needed for running kcli commands
if [ ! -f ~/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
fi

# Install kcli
curl -s https://raw.githubusercontent.com/karmab/kcli/main/install.sh | bash

echo "Ensuring clean state for VM creation"
kcli delete vm ovn-kubernetes-e2e-0 -y 2>/dev/null || true

echo "Creating test VM with Docker"
kcli create vm -i fedora42 ovn-kubernetes-e2e-0 --wait -P "cmds=['dnf install -y docker','systemctl enable --now docker']"

echo "Verifying Docker installation in VM"
if ! kcli ssh ovn-kubernetes-e2e-0 -- sudo docker version; then
  echo "ERROR: Docker installation failed in VM"
  exit 1
fi

echo "Test VM created successfully"
EOF

echo "kcli setup and VM creation completed"
