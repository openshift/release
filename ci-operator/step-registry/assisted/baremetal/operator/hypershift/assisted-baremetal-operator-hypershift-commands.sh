#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator hypershift command ************"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# shellcheck source=ci-operator/step-registry/assisted/common/lib/assisted-common-lib-commands.sh
source "${REPO_ROOT}/ci-operator/step-registry/assisted/common/lib/assisted-common-lib-commands.sh"

assisted_load_host_contract

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
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/assisted-ztp-config" "${REMOTE_TARGET}:assisted-ztp-config"
fi

tar -czf - . | ssh "${SSHOPTS[@]}" "$REMOTE_TARGET" "cat > /root/assisted-service.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "$REMOTE_TARGET" bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), \$0 }') 2>&1

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

cd "\${REPO_DIR}/deploy/operator/hypershift/"

echo "### Deploying HyperShift zero-node cluster..."

echo "export HYPERSHIFT_IMAGE=${HYPERSHIFT_IMAGE}" >> /root/config
echo "export EXTRA_BAREMETALHOSTS_FILE=/root/dev-scripts/\${EXTRA_BAREMETALHOSTS_FILE}" >> /root/config

source /root/config

# Inject job configuration for ZTP, if available
if [[ -e /root/assisted-ztp-config ]]
then
  source /root/assisted-ztp-config
fi

./deploy_hypershift_cluster.sh

EOF
