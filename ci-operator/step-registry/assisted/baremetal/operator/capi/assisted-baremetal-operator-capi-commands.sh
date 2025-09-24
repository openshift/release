#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator capi command ************"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../../common/lib/host-contract/host-contract.sh"

host_contract::load

HOST_TARGET="${HOST_SSH_USER}@${HOST_SSH_HOST}"
SSH_ARGS=("${HOST_SSH_OPTIONS[@]}")

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
  scp "${SSH_ARGS[@]}" "${SHARED_DIR}/assisted-ztp-config" "${HOST_TARGET}:assisted-ztp-config"
fi

tar -czf - . | ssh "${SSH_ARGS[@]}" "${HOST_TARGET}" "cat > /root/assisted-service.tar.gz"

# shellcheck disable=SC2087
ssh "${SSH_ARGS[@]}" "${HOST_TARGET}" bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

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

cd "\${REPO_DIR}/deploy/operator/capi/"

echo "### Deploying CAPI cluster..."

echo "export PROVIDER_IMAGE=${PROVIDER_IMAGE}" >> /root/config
echo "export HYPERSHIFT_IMAGE=${HYPERSHIFT_IMAGE}" >> /root/config
echo "export EXTRA_BAREMETALHOSTS_FILE=/root/dev-scripts/\${EXTRA_BAREMETALHOSTS_FILE}" >> /root/config

source /root/config

# Inject job configuration for ZTP, if available
if [[ -e /root/assisted-ztp-config ]]
then
  source /root/assisted-ztp-config
fi

./deploy_capi_cluster.sh

EOF
