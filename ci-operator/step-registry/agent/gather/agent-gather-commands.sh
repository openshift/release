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

echo "### Capturing node-image-pull.service logs..."
journalctl -u node-image-pull.service --no-pager -n 500 > /tmp/node-image-pull.service.log || echo "Could not capture node-image-pull.service logs"
systemctl status node-image-pull.service > /tmp/node-image-pull.service.status || echo "Could not capture node-image-pull.service status"
EOF

if scp "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/agent-gather*.tar.xz" "${ARTIFACT_DIR}/" >& /dev/null ; then
  echo "agent logs published"
fi

echo "### Capturing node-image-pull.service related logs..."
scp "${SSHOPTS[@]}" "root@${IP}:/tmp/node-image-pull.service.log" "${ARTIFACT_DIR}/" >& /dev/null || echo "Could not retrieve node-image-pull.service logs"
scp "${SSHOPTS[@]}" "root@${IP}:/tmp/node-image-pull.service.status" "${ARTIFACT_DIR}/" >& /dev/null || echo "Could not retrieve node-image-pull.service status"

echo "### Gather console screenshots..."

screenshot_archive="agent-gather-console-screenshots.tar.xz"
if [ -f "$screenshot_archive" ]; then
  cp "$screenshot_archive" "${ARTIFACT_DIR}/"
  echo "gathered $screenshot_archive"
fi
