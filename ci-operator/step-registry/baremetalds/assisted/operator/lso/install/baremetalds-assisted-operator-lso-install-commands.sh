#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator setup lso install command ************"

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

echo "### Setup LSO..."
export DISKS=\$(echo sd{b..f})
export DISCONNECTED="${DISCONNECTED}"

if [ "\${DISCONNECTED}" = "true" ]; then
  export LOCAL_REGISTRY="virthost.ostest.test.metalkube.org:5000"

  source mirror_utils.sh
  export AUTHFILE="\${XDG_RUNTIME_DIR}/containers/auth.json"
  mkdir -p \$(dirname \${AUTHFILE})
  merge_authfiles /root/dev-scripts/pull_secret.json /root/private-mirror-ostest.json "\${AUTHFILE}"
fi

source ./setup_lso.sh install_lso
source ./setup_lso.sh create_local_volume

EOF
