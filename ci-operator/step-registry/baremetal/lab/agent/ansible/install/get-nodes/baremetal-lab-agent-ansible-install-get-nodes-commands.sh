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

echo "Get nodes status"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" <<EOF
/var/builds/${NAMESPACE}/oc get nodes --kubeconfig /home/agent/install/"${NAMESPACE}"/auth/kubeconfig
EOF

