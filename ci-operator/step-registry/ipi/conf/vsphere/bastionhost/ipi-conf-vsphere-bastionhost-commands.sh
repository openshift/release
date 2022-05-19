#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

cat > "${SHARED_DIR}"/bastion_private_address <<- EOF
$(< /var/run/vault/vsphere/vmc_bastion_private_address)
EOF

cat > "${SHARED_DIR}"/bastion_ssh_user <<- EOF
$(< /var/run/vault/vsphere/vmc_bastion_ssh_user)
EOF
