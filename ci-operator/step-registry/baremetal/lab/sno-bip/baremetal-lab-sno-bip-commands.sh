#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

installation_disk=$(echo -n "${architecture:-amd64}" | sed 's/arm64/\/dev\/nvme0n1/;s/amd64/\/dev\/sda/')

cat <<EOF > "${SHARED_DIR}/sno_bip_patch_install_config.yaml"
platform:
  none: {}
bootstrapInPlace:
  installationDisk: ${installation_disk}
EOF

echo "Created install config patch to configure SNO bootstrap in place "
