#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator ztp command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

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
export ASSISTED_OPENSHIFT_INSTALL_RELEASE_IMAGE=${ASSISTED_OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}

source /root/config

export ASSISTED_OPENSHIFT_VERSION="${ASSISTED_OPENSHIFT_VERSION_OVERRIDE}"
export ASSISTED_UPGRADE_OPERATOR="${ASSISTED_UPGRADE_OPERATOR_OVERRIDE}"
export ASSISTED_STOP_AFTER_AGENT_DISCOVERY="${ASSISTED_STOP_AFTER_AGENT_DISCOVERY_OVERRIDE}"
export ASSISTED_DEPLOYMENT_METHOD="${ASSISTED_DEPLOYMENT_METHOD}"
export CHANNEL="${CHANNEL_UPGRADE_OVERRIDE}"
export ASSISTED_CLUSTER_NAME="${ASSISTED_CLUSTER_NAME}"
export ASSISTED_CLUSTER_DEPLOYMENT_NAME="${ASSISTED_CLUSTER_DEPLOYMENT_NAME}"
export ASSISTED_AGENT_CLUSTER_INSTALL_NAME="${ASSISTED_AGENT_CLUSTER_INSTALL_NAME}"
export ASSISTED_INFRAENV_NAME="${ASSISTED_INFRAENV_NAME}"

source upgrade/after_upgrade.sh

./ztp/deploy_spoke_cluster.sh

EOF
