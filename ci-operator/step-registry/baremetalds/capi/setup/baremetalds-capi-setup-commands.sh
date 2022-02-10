#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This script should install Hive, LSO, Infrastructure Operator and Hypershift
echo "************ baremetalds capi setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# Copy git source from current directory to the remote server
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/source-code.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh
export -f wrap_if_ipv6 ipversion

REPO_DIR="/home/source-code"
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar source code..."
  tar -xzvf /root/source-code.tar.gz -C "\${REPO_DIR}"
fi

cd "\${REPO_DIR}"

echo "### Setup assisted installer and other dependencies..."

images=(${ASSISTED_AGENT_IMAGE} ${ASSISTED_CONTROLLER_IMAGE} ${ASSISTED_INSTALLER_IMAGE} ${ASSISTED_IMAGE_SERVICE_IMAGE})

cat << VARS >> /root/config
export DISCONNECTED="${DISCONNECTED:-}"

export PUBLIC_CONTAINER_REGISTRIES="\$(for image in \${images}; do echo \${image} | cut -d'/' -f1; done | sort -u | paste -sd ',' -)"

# Fix for disconnected Hive
export GO_REQUIRED_MIN_VERSION="1.14.4"
VARS

# Override default images
echo "export SERVICE=${ASSISTED_SERVICE_IMAGE}" >> /root/config
echo "export AGENT_DOCKER_IMAGE=${ASSISTED_AGENT_IMAGE}" >> /root/config
echo "export CONTROLLER_IMAGE=${ASSISTED_CONTROLLER_IMAGE}" >> /root/config
echo "export INSTALLER_IMAGE=${ASSISTED_INSTALLER_IMAGE}" >> /root/config
echo "export IMAGE_SERVICE_IMAGE=${ASSISTED_IMAGE_SERVICE_IMAGE}" >> /root/config
# Most jobs and tests don't require this image, so this allows it as optional
if [ "${PROVIDER_IMAGE}" != "${ASSISTED_CONTROLLER_IMAGE}" ];
then
  echo "export PROVIDER_IMAGE=${PROVIDER_IMAGE}" >> /root/config
fi
# Most jobs and tests don't require this image, so this allows it as optional
if [ "${HYPERSHIFT_IMAGE}" != "${ASSISTED_CONTROLLER_IMAGE}" ];
then
  echo "export HYPERSHIFT_IMAGE=${HYPERSHIFT_IMAGE}" >> /root/config
fi

source /root/config

# deploy/operator/deploy.sh

### (mko) Everything above is copied&cleaned from ci-operator/step-registry/baremetalds/assisted/operator/setup/baremetalds-assisted-operator-setup-commands.sh
###       and below we should write a code that gets LSO, Hive and Assisted subscriptions in the cluster and applies them with `oc`.
###       Sample file for LSO is github.com/assisted-service/deploy/operator/deploy.sh together with
###       github.com/assisted-service/deploy/operator/setup_lso.sh
###       The easiest here is to git-clone assisted-service repository and consume those scripts as-is.

###       Some parts above also come from ci-operator/step-registry/baremetalds/assisted/setup/baremetalds-assisted-setup-commands.sh
###       so that this setup here is a combination of different stuff we learned in the Assisted CI.

###       For sanity in here we will just refer to scripts available in cluster-api-provider-agent/deploy/ and not write
###       the whole logic in openshift/release. This is a tradeoff so that we don't have too much of a shell inside a shell.

echo "### Deploying prerequisites for CAPI Provider Agent..."

cd "\${REPO_DIR}/"
# cd "\${REPO_DIR}/deploy/"
# ./prerequisites.sh

echo "### THIS IS A DEBUG"
cat /root/config

EOF
