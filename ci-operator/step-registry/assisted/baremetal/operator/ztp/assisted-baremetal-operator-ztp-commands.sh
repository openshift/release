#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator ztp command ************"

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
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

REPO_DIR="/home/assisted-service"
if [ ! -d "${REPO_DIR}" ]; then
  mkdir -p "${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "${REPO_DIR}"
fi

cd "${REPO_DIR}/deploy/operator/ztp/"

echo "### Deploying spoke cluster..."

export EXTRA_BAREMETALHOSTS_FILE="/root/dev-scripts/${EXTRA_BAREMETALHOSTS_FILE}"

source /root/config

# Inject job configuration for ZTP, if available 
if [[ -e /root/assisted-ztp-config ]]
then
  source /root/assisted-ztp-config
fi

# Remove the nodes allocated for Day2 from EXTRA_BAREMETALHOSTS_FILE when deploying the spoke.
# If no day2 hosts are required then all nodes will be used for the spoke.
# If some day 2 hosts are defined, they will be used in the step `assisted-baremetal-operator-add-day2-workers-optionally`
if [ -z "$NUMBER_OF_DAY2_HOSTS" ]
then
  cat "${EXTRA_BAREMETALHOSTS_FILE}" > /root/dev-scripts/cluster_bmh.json
else
  # Take the first (n - NUMBER_OF_DAY2_HOSTS) where n is the total host count in EXTRA_BAREMETALHOSTS_FILE
  cat "${EXTRA_BAREMETALHOSTS_FILE}" | jq --arg DAY_2_HOSTS ${NUMBER_OF_DAY2_HOSTS:-0} '.[:-($DAY_2_HOSTS | tonumber)]' > /root/dev-scripts/cluster_bmh.json
fi

cat /root/dev-scripts/cluster_bmh.json

EXTRA_BAREMETALHOSTS_FILE="/root/dev-scripts/cluster_bmh.json" ./deploy_spoke_cluster.sh

EOF
