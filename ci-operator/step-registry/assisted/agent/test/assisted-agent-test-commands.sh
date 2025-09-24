#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ assisted agent test command ************"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common/lib/host-contract/host-contract.sh"

host_contract::load

HOST_TARGET="${HOST_SSH_USER}@${HOST_SSH_HOST}"
SSH_ARGS=("${HOST_SSH_OPTIONS[@]}")

echo "### Running tests"
timeout --kill-after 10m 120m ssh "${SSH_ARGS[@]}" "${HOST_TARGET}" bash - << EOF
    cd /home/assisted
    skipper make subsystem
EOF
