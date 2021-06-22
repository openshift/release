#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator setup lso install command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted-service.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF

cd /root/dev-scripts
source common.sh

set -xeo pipefail

REPO_DIR="/home/assisted-service"
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "\${REPO_DIR}"
fi

cd "\${REPO_DIR}/deploy/operator/"

echo "### Setup LSO..."
export DISKS=\$(echo sd{b..f})
export DISCONNECTED="${DISCONNECTED}"

if [ "\${DISCONNECTED}" = "true" ]; then
  export AUTHFILE="\${XDG_RUNTIME_DIR}/containers/auth.json"
  export LOCAL_REGISTRY="\${LOCAL_REGISTRY_DNS_NAME}:\${LOCAL_REGISTRY_PORT}"

  source mirror_utils.sh
  mkdir -p \$(dirname \${AUTHFILE})

  merge_authfiles "\${PULL_SECRET_FILE}" "\${REGISTRY_CREDS}" "\${AUTHFILE}"
fi

./setup_lso.sh install_lso
./setup_lso.sh create_local_volume

EOF
