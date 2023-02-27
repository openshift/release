#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ add-worker command ************"

source "${SHARED_DIR}/packet-conf.sh"
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted-service.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

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

cd "\${REPO_DIR}/deploy/operator/"
git clone https://github.com/LiangquanLi930/deployhypershift.git
cd "deployhypershift"

echo "export EXTRA_BAREMETALHOSTS_FILE=/root/dev-scripts/\${EXTRA_BAREMETALHOSTS_FILE}" >> /root/config
source /root/config

./deploy_hypershift.sh

set -x
EOF