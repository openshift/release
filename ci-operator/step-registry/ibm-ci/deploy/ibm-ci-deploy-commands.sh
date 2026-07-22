#!/bin/bash
set -euo pipefail

# Setup SSH from Vault secret (base64-encoded private key)
cat /var/run/ibm-ci/private-key | base64 -d > /tmp/id_rsa
echo "" >> /tmp/id_rsa
chmod 600 /tmp/id_rsa

# Setup pull secret
cp /var/run/ibm-ci/pull-secret /tmp/pull-secret.json

# Generate Ansible inventory
mkdir -p ansible/inventory
cat > ansible/inventory/hosts.yml <<EOF
---
all:
  children:
    ibm_hosts:
      hosts:
        ${IBM_HOST}:
          ansible_user: root
          ansible_ssh_private_key_file: /tmp/id_rsa
EOF

# Run deployment
make -C ansible install
