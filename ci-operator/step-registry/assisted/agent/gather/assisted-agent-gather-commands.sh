#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ assisted agent gather command ************"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# shellcheck source=ci-operator/step-registry/assisted/common/lib/assisted-common-lib-commands.sh
source "${REPO_ROOT}/ci-operator/step-registry/assisted/common/lib/assisted-common-lib-commands.sh"

assisted_load_host_contract

echo "### Gathering artifacts"
timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "$REMOTE_TARGET" bash - << EOF
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

scp "${SSHOPTS[@]}" "${REMOTE_TARGET}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
