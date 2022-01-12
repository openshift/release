#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

mirror_registry_url="$(< /var/run/vault/vsphere/vmc_mirror_registry_url)"

cat > "${SHARED_DIR}"/mirror_registry_url << EOF
${mirror_registry_url}
EOF
