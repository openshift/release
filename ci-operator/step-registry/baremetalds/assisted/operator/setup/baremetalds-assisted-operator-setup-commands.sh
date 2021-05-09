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
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "\${REPO_DIR}"
fi

cd "\${REPO_DIR}/deploy/operator/"

export DISCONNECTED="${DISCONNECTED}"

echo "### Setup hive..."

if [ "\${DISCONNECTED}" = "true" ]; then
  source ../../hack/setup_env.sh hive_from_upstream

  export LOCAL_REGISTRY="virthost.ostest.test.metalkube.org:5000"
  export AUTHFILE="/root/private-mirror-ostest.json"
  source ./setup_hive.sh from_upstream
else
  source ./setup_hive.sh with_olm
fi

if [ "\${DISCONNECTED}" = "true" ]; then
  echo "AI operator installation on disconnected environment not yet implemented"
  exit 0
fi

echo "### Setup assisted installer..."
export INDEX_IMAGE=${INDEX_IMAGE}
source ./setup_assisted_operator.sh

EOF
