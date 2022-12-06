#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ agent gather command ************"
echo "### Gathering logs..."
timeout -s 9 5m ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF
cd dev-scripts
make agent_gather
scp agent-gather.tar.xz "${ARTIFACT_DIR}"
EOF
