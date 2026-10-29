#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ assisted agent test command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Running tests"
timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
    cd /home/assisted
    skipper make subsystem
EOF
