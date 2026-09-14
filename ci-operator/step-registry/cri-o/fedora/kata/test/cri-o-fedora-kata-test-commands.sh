#!/bin/bash
set -xeuo pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
chmod +x ${SHARED_DIR}/login_script.sh
${SHARED_DIR}/login_script.sh

# Forward the Prow job environment so that the CRI-O test runner can select
# the integration tests affected by the pull request (see hack/ci in cri-o).
PULL_BASE_SHA=${PULL_BASE_SHA:-}
JOB_TYPE=${JOB_TYPE:-}

timeout --kill-after 10m 400m ssh "${SSHOPTS[@]}" ${IP} -- bash - <<EOF
    SOURCE_DIR="/usr/go/src/github.com/cri-o/cri-o"
    cd "\${SOURCE_DIR}/contrib/test/ci"
    export PULL_BASE_SHA="${PULL_BASE_SHA}" JOB_TYPE="${JOB_TYPE}"
    ansible-playbook integration-main.yml -i hosts -e "TEST_AGENT=prow" -e "build_kata=True" --connection=local -vvv
EOF
