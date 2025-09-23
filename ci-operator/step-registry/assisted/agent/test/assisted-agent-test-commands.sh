#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ assisted agent test command ************"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# shellcheck source=ci-operator/step-registry/assisted/common/lib/assisted-common-lib-commands.sh
source "${REPO_ROOT}/ci-operator/step-registry/assisted/common/lib/assisted-common-lib-commands.sh"

assisted_load_host_contract

echo "### Running tests"
timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "$REMOTE_TARGET" bash - << EOF
    cd /home/assisted
    skipper make subsystem
EOF
