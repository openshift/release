#!/bin/bash

if [ -n "${LOCAL_TEST}" ]; then
  # Setting LOCAL_TEST to any value will allow testing this script with default values against the ARM64 bastion @ RDU2
  export N_MASTERS=1 N_WORKERS=1 IPI=true AUX_HOST=openshift-qe-bastion.arm.eng.rdu2.redhat.com
  # shellcheck disable=SC2155
  export NAMESPACE=test-ci-op SHARED_DIR=$(mktemp -d) CLUSTER_PROFILE_DIR=~/.ssh
fi

set -o nounset
set -o errexit
set -o pipefail

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

# The hostname of nodes and the cluster names have limited length for BM.
# Other profiles add to the cluster_name the suffix "-${JOB_NAME_HASH}".
echo "${NAMESPACE}" > "${SHARED_DIR}/cluster_name"

timeout -s 9 180m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${NAMESPACE}" "${N_MASTERS}" "${N_WORKERS}" "${IPI}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail
set -o allexport

BUILD_USER=ci-op
BUILD_ID="${1}"
N_MASTERS="${2}"
N_WORKERS="${3}"
IPI="${4}"
set +o allexport

# shellcheck disable=SC2174
mkdir -m 755 -p {/var/builds,/opt/tftpboot,/opt/html}/${BUILD_ID}
touch /etc/{hosts_pool_reserved,vips_reserved}
# The current implementation of the following scripts is different based on the auxiliary host. Keeping the script in
# the remote aux servers temporarily.
bash /usr/local/bin/reserve_hosts.sh
bash /usr/local/bin/reserve_vips.sh
EOF

scp "${SSHOPTS[@]}" "root@${AUX_HOST}:/var/builds/${NAMESPACE}/*.yaml" "${SHARED_DIR}/"

more "${SHARED_DIR}"/* |& sed 's/pass.*$/pass ** HIDDEN **/g'
