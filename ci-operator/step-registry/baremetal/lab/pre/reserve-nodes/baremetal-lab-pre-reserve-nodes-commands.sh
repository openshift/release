#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

[ -z "${AUX_HOST}" ] && {  echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${masters}" ] && {  echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${workers}" ] && {  echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${IPI}" ] && {  echo "\$AUX_HOST is not filled. Failing."; exit 1; }

# The hostname of nodes and the cluster names have limited length for BM.
# Other profiles add to the cluster_name the suffix "-${JOB_NAME_HASH}".
echo "${NAMESPACE}" > "${SHARED_DIR}/cluster_name"
echo "Reserving nodes for baremetal installation (${masters} masters, ${workers} workers) $([ "$IPI" != true ] && echo "+ 1 bootstrap physical node")..."
timeout -s 9 180m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${NAMESPACE}" "${masters}" "${workers}" "${IPI}" << 'EOF'
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

echo "Node reservation concluded successfully."
scp "${SSHOPTS[@]}" "root@${AUX_HOST}:/var/builds/${NAMESPACE}/*.yaml" "${SHARED_DIR}/"
more "${SHARED_DIR}"/*.yaml |& sed 's/pass.*$/pass ** HIDDEN **/g'
