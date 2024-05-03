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

cd ${remote_workdir}/topolvm

make -C test/e2e incluster-lvmd/create-vg
make -C test/e2e incluster-lvmd/setup-minikube
make -C test/e2e incluster-lvmd/launch-minikube
make -C test/e2e incluster-lvmd/test

EOF

chmod +x ${SHARED_DIR}/install.sh
scp "${SSHOPTS[@]}" ${SHARED_DIR}/install.sh $ssh_host_ip:$remote_workdir

ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/install.sh"