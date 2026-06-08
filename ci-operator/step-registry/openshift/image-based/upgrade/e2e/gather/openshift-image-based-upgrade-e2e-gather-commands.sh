#!/bin/bash
set -x
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

remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"
remote_artifacts_dir=${remote_workdir}/artifacts

echo "Compressing e2e artifacts..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "tar czvf ${remote_workdir}/e2e_artifacts.tar.gz -C ${remote_artifacts_dir} ."

echo "Transferring e2e artifacts..."
scp "${SSHOPTS[@]}" $ssh_host_ip:$remote_workdir/e2e_artifacts.tar.gz ${ARTIFACT_DIR}

echo "Extracting test artifacts..."
tar -xvf ${ARTIFACT_DIR}/e2e_artifacts.tar.gz -C ${ARTIFACT_DIR}
