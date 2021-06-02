#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

git clone https://github.com/osherdp/assisted-service --branch feature/disconnected-mode-for-assisted-service
cd assisted-service/
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted-service.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF

set -xeo pipefail

cd /root/dev-scripts
source common.sh

REPO_DIR="/home/assisted-service"
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "\${REPO_DIR}"
fi

cd "\${REPO_DIR}"

export DISCONNECTED="${DISCONNECTED:-}"

echo "### Setup hive..."

if [ "\${DISCONNECTED}" = "true" ]; then
  hack/setup_env.sh hive_from_upstream

  export LOCAL_REGISTRY="\${LOCAL_REGISTRY_DNS_NAME}:\${LOCAL_REGISTRY_PORT}"
  export AUTHFILE="\${REGISTRY_CREDS}"
  deploy/operator/setup_hive.sh from_upstream
else
  deploy/operator/setup_hive.sh with_olm
fi

if [ "\${DISCONNECTED}" = "true" ]; then
  echo "AI operator installation on disconnected environment not yet implemented"
  exit 0
fi

echo "### Setup assisted installer..."
export INDEX_IMAGE=${INDEX_IMAGE}

images=(${ASSISTED_AGENT_IMAGE} ${ASSISTED_CONTROLLER_IMAGE} ${ASSISTED_INSTALLER_IMAGE})
export PUBLIC_CONTAINER_REGISTRIES=\$(for image in \${images}; do echo \${image} | cut -d'/' -f1; done | sort -u | paste -sd "," -)
deploy/operator/setup_assisted_operator.sh

EOF
