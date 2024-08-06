#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
export PS4='+ $(date "+%T.%N") \011'

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)

ssh_host_ip="$host@$instance_ip"

if ! test -f "${SHARED_DIR}/remote_workdir"; then
  workdir="/home/${host}/workdir-$(date +%Y%m%d)"

  echo "${workdir}" >> "${SHARED_DIR}/remote_workdir"
fi

remote_workdir=$(cat "${SHARED_DIR}/remote_workdir")

ssh "${SSHOPTS[@]}" "${ssh_host_ip}" "mkdir -p ${remote_workdir}"

cat <<EOF > ${SHARED_DIR}/run-conformance.sh
#!/bin/bash
set -euo pipefail

PATH=$PATH:${remote_workdir}/go/bin

make -C ${remote_workdir}/topolvm/test/e2e \
    TEST_SCHEDULER_EXTENDER_TYPE=${TEST_SCHEDULER_EXTENDER_TYPE} \
    TEST_LVMD_TYPE=${TEST_LVMD_TYPE} \
    KUBERNETES_VERSION=${KUBERNETES_VERSION} \
    incluster-lvmd/create-vg \
    incluster-lvmd/setup-minikube \
    incluster-lvmd/launch-minikube \
    incluster-lvmd/test

EOF

chmod +x ${SHARED_DIR}/run-conformance.sh
scp "${SSHOPTS[@]}" ${SHARED_DIR}/run-conformance.sh $ssh_host_ip:$remote_workdir

ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/run-conformance.sh"
