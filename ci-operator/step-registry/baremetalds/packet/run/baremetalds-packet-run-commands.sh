#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds packet run command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

function getlogs() {
  echo "### Downloading logs..."
  scp -r "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT

timeout -s 9 ${PACKET_TIMEOUT} ssh "${SSHOPTS[@]}" "root@${IP}" ${PACKET_COMMAND}
