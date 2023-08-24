#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


echo "Building SSHOPTS"

SSHOPTS=(-o 'ConnectTimeout=5'
-o 'StrictHostKeyChecking=no'
-o 'UserKnownHostsFile=/dev/null'
-o 'ServerAliveInterval=90'
-o LogLevel=ERROR
-i "${CLUSTER_PROFILE_DIR}/ssh-key")

echo "Wait for Bootstrap complete"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" <<EOF
/home/agent/install/"${NAMESPACE}"/openshift-install agent wait-for bootstrap-complete --log-level debug --dir /home/agent/install/"${NAMESPACE}"/
EOF

