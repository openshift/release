#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator ztp add day2 workers optionally command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

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

echo "### Sourcing root config."

source /root/config

echo "### Injecting ZTP configuration."

# Inject job configuration for ZTP, if available
if [[ -e /root/assisted-ztp-config ]]
then
  source /root/assisted-ztp-config
fi

echo "### Done injecting ZTP configuration."

# Use only the nodes allocated for Day2 in the EXTRA_BAREMETALHOSTS_FILE when deploying the workers.
# These are the last NUMBER_OF_DAY2_HOSTS in this file: '/root/dev-scripts/${EXTRA_BAREMETALHOSTS_FILE}'

if [ -z "$NUMBER_OF_DAY2_HOSTS" ]
then
  echo "No day 2 hosts defined, skipping day 2 hosts"
  exit 0
fi

cat "/root/dev-scripts/${EXTRA_BAREMETALHOSTS_FILE}" | jq --arg DAY_2_HOSTS ${NUMBER_OF_DAY2_HOSTS:-0} '.[-($DAY_2_HOSTS | tonumber):]' > /root/dev-scripts/day2_worker_bmh.json
cat /root/dev-scripts/day2_worker_bmh.json
echo "### Deploying second day worker."
export REMOTE_BAREMETALHOSTS_FILE=/root/dev-scripts/day2_worker_bmh.json
export ASSISTED_INFRAENV_NAME="${ASSISTED_INFRAENV_NAME:-assisted-infra-env}"
./add_day2_remote_nodes.sh

EOF
