#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ agent gather command ************"
# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Gathering logs..."
gather_status=0
timeout -s 9 15m ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF || gather_status=$?
cd dev-scripts
make agent_gather
EOF

copy_status=0
if scp "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/agent-gather*.tar.xz" "${ARTIFACT_DIR}/" >& /dev/null ; then
  echo "agent logs published"
else
  copy_status=$?
  echo "Agent archive download failed (exit ${copy_status}); collection exit ${gather_status}" >&2
fi
if ! scp "${SSHOPTS[@]}" "root@${IP}:/root/dev-scripts/ocp/*/installation-logs.tar" "${ARTIFACT_DIR}/" >& /dev/null; then
  echo "Optional installation logs unavailable" >&2
fi
echo "Agent collection exit ${gather_status}; archive download exit ${copy_status}"
if (( gather_status != 0 )); then exit "${gather_status}"; fi
exit "${copy_status}"
