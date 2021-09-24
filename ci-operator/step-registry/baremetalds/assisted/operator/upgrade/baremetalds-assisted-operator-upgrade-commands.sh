#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator upgrade command ************"

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

# cd /root/dev-scripts
# source common.sh
# source utils.sh
# source network.sh

REPO_DIR="/home/assisted-service"
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "\${REPO_DIR}"
fi

cd "\${REPO_DIR}/deploy/operator/"


echo "### Upgrading AI operator..."

export CHANNEL_UPGRADE_OVERRIDE="${CHANNEL_UPGRADE_OVERRIDE}"

# source /root/config

# # Inject job configuration for ZTP, if available
# if [[ -e /root/assisted-ztp-config ]]
# then
#   source /root/assisted-ztp-config
# fi

./upgrade/upgrade.sh

EOF
