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
EOF

if scp "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/agent-gather*.tar.xz" "${ARTIFACT_DIR}/" >& /dev/null ; then
  echo "agent logs published"
fi

echo "### Gather console screenshots..."

screenshot_archive="agent-gather-console-screenshots.tar.xz"
if [ -f "$screenshot_archive" ]; then
  cp "$screenshot_archive" "${ARTIFACT_DIR}/"
  echo "gathered $screenshot_archive"
fi
