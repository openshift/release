#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ agent gather command ************"
getlogs() {
  local original_status=$? pattern retrieval_status
  trap - EXIT
  set +e
  if [[ -n "${IP:-}" ]] && declare -p SSHOPTS >/dev/null 2>&1; then
    for pattern in '/root/dev-scripts/agent-gather*.tar.xz' '/root/dev-scripts/ocp/*/installation-logs.tar'; do
      timeout --kill-after=5s 45s scp "${SSHOPTS[@]}" "root@${IP}:${pattern}" "${ARTIFACT_DIR}/" >/dev/null 2>&1
      retrieval_status=$?
      echo "Agent bundle retrieval: ${pattern}, rc=${retrieval_status} (nonzero: missing matches or transfer failure; packed contents/readability unverified)"
    done
  else
    echo "Agent bundle retrieval skipped: provisioning configuration unavailable"
  fi
  exit "${original_status}"
}
trap getlogs EXIT
# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Gathering logs..."
status=0
timeout --kill-after=5s 15m ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF || status=$?
cd dev-scripts
make agent_gather
EOF

echo "Agent gather rc=${status}; 124 denotes timeout, 137 denotes SIGKILL with unknown cause; zero does not prove complete diagnostics"
exit "${status}"
