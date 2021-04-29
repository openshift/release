#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

git clone https://github.com/openshift/assisted-service
cd assisted-service/
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted-service.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF

set -xeo pipefail

REPO_DIR="/home/assisted-service"
if [ ! -d "\$REPO_DIR" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "\${REPO_DIR}"
fi

cd "\${REPO_DIR}/deploy/operator/"

echo "### Setup hive..."
source ./setup_hive.sh

echo "### Setup assisted installer..."
export INDEX_IMAGE=${INDEX_IMAGE}
source ./setup_assisted_operator.sh

EOF
