#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator ztp day2 command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"
source "${SHARED_DIR}/ds-vars.conf"

# Copy env variables set by baremetalds-devscripts-setup to remote server
scp "${SSHOPTS[@]}" "${SHARED_DIR}/ds-vars.conf" "root@${IP}:ds-vars.conf"

# Copy over the ENV variables set in remote_nodes.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}/remote-vars.conf" "root@${IP}:remote-vars.conf"

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
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

set -xeo pipefail

REPO_DIR="/home/assisted-service"
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "\${REPO_DIR}"
fi

echo "### Adding remote nodes to spoke cluster..."

# Inject variables from devscripts-remotenodes
source /root/remote-vars.conf

# Inject variables from devscripts-setup
source /root/ds-vars.conf

# TODO(lranjbar): Add CLUSTER_NAME and OCP_DIR to the devscripts-setup ds-vars.conf
export OCP_DIR="\${DS_WORKING_DIR}/\${CLUSTER_NAME}"

# Inject job configuration for ZTP, if available
if [[ -e /root/assisted-ztp-config ]]
then
  source /root/assisted-ztp-config
fi

cd "\${REPO_DIR}/deploy/operator/ztp/"

# TODO(lranjbar): Fix the permissions on this file
#chmod 755 add_day2_remote_nodes.sh
#./add_day2_remote_nodes.sh

# TODO(lranjbar): Make updates to add_day2_remote_nodes.sh and remove this paste of the script

export REMOTE_BAREMETALHOSTS_FILE="\${REMOTE_BAREMETALHOSTS_FILE:-/home/test/dev-scripts/ocp/ostest/remote_baremetalhosts.json}"
export ASSISTED_INFRAENV_NAME="\${ASSISTED_INFRAENV_NAME:-assisted-infra-env}"
export SPOKE_NAMESPACE="\${SPOKE_NAMESPACE:-assisted-spoke-cluster}"

echo "Adding remote nodes to spoke cluster"
ansible-playbook add-remote-nodes-playbook.yaml

sleep 1h

EOF
