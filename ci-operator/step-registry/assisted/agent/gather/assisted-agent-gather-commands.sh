#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ assisted agent gather command ************"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common/lib/host-contract/host-contract.sh"

host_contract::load

HOST_TARGET="${HOST_SSH_USER}@${HOST_SSH_HOST}"
SSH_ARGS=("${HOST_SSH_OPTIONS[@]}")

echo "### Gathering artifacts"
timeout --kill-after 10m 120m ssh "${SSH_ARGS[@]}" "${HOST_TARGET}" bash - << EOF
    mkdir /tmp/artifacts

    # collect junit reports and logs
    cd /home/assisted
    find -name 'junit*.xml' -exec cp -v {} /tmp/artifacts \; || true
    find -name '*.log' -exec cp -v {} /tmp/artifacts \; || true

    # sos report
    sos report --batch --tmp-dir /tmp/artifacts \
        -o docker,logs,networkmanager,networking \
        -k docker.all -k docker.logs
EOF

scp "${SSH_ARGS[@]}" "${HOST_TARGET}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
