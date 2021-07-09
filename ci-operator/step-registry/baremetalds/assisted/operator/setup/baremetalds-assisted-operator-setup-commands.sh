#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted-service.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh
export -f wrap_if_ipv6 ipversion

REPO_DIR="/home/assisted-service"
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "\${REPO_DIR}"
fi

cd "\${REPO_DIR}"

export DISCONNECTED="${DISCONNECTED:-}"

echo "### Setup assisted installer..."

# TODO: remove this and support mirroring an index referenced by digest value
# https://issues.redhat.com/browse/MGMT-6858
export INDEX_IMAGE="\$(dirname ${INDEX_IMAGE})/pipeline:ci-index"

images=(${ASSISTED_AGENT_IMAGE} ${ASSISTED_CONTROLLER_IMAGE} ${ASSISTED_INSTALLER_IMAGE})
export PUBLIC_CONTAINER_REGISTRIES=\$(for image in \${images}; do echo \${image} | cut -d'/' -f1; done | sort -u | paste -sd "," -)

# Fix for disconnected Hive
export GO_REQUIRED_MIN_VERSION="1.14.4"

deploy/operator/deploy.sh

EOF
