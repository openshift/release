#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator ztp command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# # ZTP scripts have a lot of default values for the spoke cluster configuration. Adding this so that they can be changed.
# if [[ -n "${ASSISTED_ZTP_CONFIG:-}" ]]; then
#   readarray -t config <<< "${ASSISTED_ZTP_CONFIG}"
#   for var in "${config[@]}"; do
#     if [[ ! -z "${var}" ]]; then
#       echo "export ${var}" >> "${SHARED_DIR}/assisted-ztp-config"
#     fi
#   done
# fi

# # Copy configuration for ZTP vars if present
# if [[ -e "${SHARED_DIR}/assisted-ztp-config" ]]
# then
#   scp "${SSHOPTS[@]}" "${SHARED_DIR}/assisted-ztp-config" "root@${IP}:assisted-ztp-config"
# fi

tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted-service.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

REPO_DIR="/home/assisted-service"
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "\${REPO_DIR}"
fi

cd "\${REPO_DIR}/deploy/operator/"


echo "### Deploying spoke cluster..."

export EXTRA_BAREMETALHOSTS_FILE="/root/dev-scripts/\${EXTRA_BAREMETALHOSTS_FILE}"

source /root/config

# # Inject job configuration for ZTP, if available
# if [[ -e /root/assisted-ztp-config ]]
# then
#   source /root/assisted-ztp-config
# fi

# TODO(ppinjark): Fix after_upgrade.sh file to use override variables
# source upgrade/after_upgrade.sh

export ASSISTED_UPGRADE_OPERATOR="${ASSISTED_UPGRADE_OPERATOR_OVERRIDE}"
export ASSISTED_STOP_AFTER_AGENT_DISCOVERY="${ASSISTED_STOP_AFTER_AGENT_DISCOVERY_OVERRIDE}"
export ASSISTED_CLUSTER_NAME="${ASSISTED_CLUSTER_NAME}"
export ASSISTED_CLUSTER_DEPLOYMENT_NAME="${ASSISTED_CLUSTER_DEPLOYMENT_NAME}"
export ASSISTED_AGENT_CLUSTER_INSTALL_NAME="${ASSISTED_AGENT_CLUSTER_INSTALL_NAME}"
export ASSISTED_INFRAENV_NAME="${ASSISTED_INFRAENV_NAME}"

# TODO(ppinjark): Fix common.sh file to use override variables
export ASSISTED_OPENSHIFT_VERSION="openshift-v4.9.0"

./ztp/deploy_spoke_cluster.sh

EOF
