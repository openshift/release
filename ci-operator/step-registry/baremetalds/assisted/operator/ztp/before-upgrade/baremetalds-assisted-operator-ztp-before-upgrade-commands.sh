#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator ztp before upgrade command ************"

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

export ASSISTED_OPENSHIFT_VERSION="${ASSISTED_OPENSHIFT_VERSION}"
export ASSISTED_UPGRADE_OPERATOR="${ASSISTED_UPGRADE_OPERATOR}"
export ASSISTED_STOP_AFTER_AGENT_DISCOVERY="${ASSISTED_STOP_AFTER_AGENT_DISCOVERY}"
export ASSISTED_DEPLOYMENT_METHOD="${ASSISTED_DEPLOYMENT_METHOD}"
export CHANNEL="${CHANNEL_INSTALL_OVERRIDE}"

export ASSISTED_OPENSHIFT_INSTALL_RELEASE_IMAGE=${ASSISTED_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}

source /root/config

source upgrade/before_upgrade.sh

./ztp/deploy_spoke_cluster.sh

EOF
