#!/bin/bash
set -xeuo pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
chmod +x ${SHARED_DIR}/login_script.sh
${SHARED_DIR}/login_script.sh
timeout --kill-after 10m 400m ssh "${SSHOPTS[@]}" ${IP} -- bash - <<EOF
    SOURCE_DIR="/usr/go/src/github.com/cri-o/cri-o"
    cd "\${SOURCE_DIR}/contrib/test/ci"
    ansible-playbook e2e-main.yml -i hosts -e "TEST_AGENT=prow" --connection=local -vvv --tags e2e --extra-vars "cgroupv2=True"
EOF

