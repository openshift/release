#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator setup before upgrade command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# ZTP scripts have a lot of default values for the spoke cluster configuration. Adding this so that they can be changed.
if [[ -n "${ASSISTED_ZTP_CONFIG:-}" ]]; then
  readarray -t config <<< "${ASSISTED_ZTP_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then
      echo "export ${var}" >> "${SHARED_DIR}/assisted-ztp-config"
    fi
  done
fi

# Copy configuration for ZTP vars if present
if [[ -e "${SHARED_DIR}/assisted-ztp-config" ]]
then
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/assisted-ztp-config" "root@${IP}:assisted-ztp-config"
fi

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

echo "### Setup assisted installer..."

images=(${ASSISTED_AGENT_IMAGE} ${ASSISTED_CONTROLLER_IMAGE} ${ASSISTED_INSTALLER_IMAGE})

cat << VARS >> /root/config

export DISCONNECTED="false"
export INDEX_IMAGE="${INDEX_IMAGE}"

export PUBLIC_CONTAINER_REGISTRIES="\$(for image in \${images}; do echo \${image} | cut -d'/' -f1; done | sort -u | paste -sd ',' -)"

# Fix for disconnected Hive
export GO_REQUIRED_MIN_VERSION="1.14.4"
VARS

source /root/config

# Inject job configuration for ZTP, if available
if [[ -e /root/assisted-ztp-config ]]
then
  source /root/assisted-ztp-config
fi

source deploy/operator/upgrade/before_upgrade.sh

deploy/operator/deploy.sh

EOF
