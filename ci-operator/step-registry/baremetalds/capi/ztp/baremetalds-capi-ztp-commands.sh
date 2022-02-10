#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This script should call a script inside cluster-api-provider-agent repo,
# e.g. ./deploy_capi_cluster.sh that will create InfraEnv CR as well as BMH
# so that the HyperShift installation has to start
echo "************ baremetalds capi ztp command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# Copy git source from current directory to the remote server
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/source-code.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

set -xeo pipefail

# cd /root/dev-scripts
# source common.sh
# source utils.sh
# source network.sh

REPO_DIR="/home/source-code"
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar source code..."
  tar -xzvf /root/source-code.tar.gz -C "\${REPO_DIR}"
fi

export EXTRA_BAREMETALHOSTS_FILE="/root/dev-scripts/\${EXTRA_BAREMETALHOSTS_FILE}"
source /root/config

### (mko) Everything above is copied&cleaned from ci-operator/step-registry/baremetalds/assisted/operator/ztp/baremetalds-assisted-operator-ztp-commands.sh
###       and below we should write a code that does the main logic of the E2E CAPI test, i.e. deploy HyperShift hosted
###       control plane, create HyperShift cluster, create InfraEnv for Infrastructure Operator, apply BMH available in EXTRA_BAREMETALHOSTS_FILE,
###       wait for Agent to appear, then scale up the HyperShift cluster and see if Agent gets picked.

###       For sanity in here we will just refer to scripts available in cluster-api-provider-agent/deploy/ and not write
###       the whole logic in openshift/release. This is a tradeoff so that we don't have too much of a shell inside a shell.

cd "\${REPO_DIR}/"
# cd "\${REPO_DIR}/deploy/"

echo "### THIS IS A DEBUG"
cat /root/config

echo "### Creating HyperShift hosted control plane..."
# ./deploy_hypershift_hosted_cp.sh

echo "### Creating InfraEnv and BMH and whatnot..."
# ./deploy_hypershift_worker.sh

EOF
