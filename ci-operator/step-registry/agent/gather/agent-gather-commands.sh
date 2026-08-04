#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ agent gather command ************"
# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Gathering logs..."
timeout -s 9 15m ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF
cd dev-scripts
make agent_gather
EOF

if scp "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/agent-gather*.tar.xz" "root@${IP}:/root/dev-scripts/ocp/*/installation-logs.tar" "${ARTIFACT_DIR}/" >& /dev/null ; then
  echo "agent logs published"
fi
