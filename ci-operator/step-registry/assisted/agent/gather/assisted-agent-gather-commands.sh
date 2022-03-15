#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ assisted agent gather command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "### Gathering artifacts"
timeout --kill-after 10m 120m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
    mkdir /tmp/artifacts

    # collect junit reports and logs
    cd /home/assisted
    find -name 'junit*.xml' -exec cp -v {} /tmp/artifacts \; || true
    find -name '*.log' -exec cp -v {} /tmp/artifacts \; || true

    # sos report
    sos report --batch --tmp-dir /tmp/artifacts \
        -o docker \
        -k docker.all -k docker.logs
EOF

scp "${SSHOPTS[@]}" "root@${IP}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
