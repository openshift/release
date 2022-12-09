#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ agent gather command ************"
# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Gathering logs..."
timeout -s 9 5m ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF
cd dev-scripts
make agent_gather
cp agent-gather*.tar.xz "${ARTIFACT_DIR}"
EOF
