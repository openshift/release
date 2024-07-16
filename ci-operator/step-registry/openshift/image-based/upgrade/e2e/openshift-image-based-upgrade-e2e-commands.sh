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

remote_workdir=$(cat ${SHARED_DIR}/remote_workdir)
instance_ip=$(cat ${SHARED_DIR}/public_address)
host=$(cat ${SHARED_DIR}/ssh_user)
ssh_host_ip="$host@$instance_ip"
PULL_SECRET_FILE=$(cat ${SHARED_DIR}/pull_secret_file)

TARGET_VM_NAME=$(cat ${SHARED_DIR}/target_vm_name)
target_kubeconfig=${remote_workdir}/ib-orchestrate-vm/bip-orchestrate-vm/workdir-${TARGET_VM_NAME}/auth/kubeconfig
remote_artifacts_dir=${remote_workdir}/artifacts

cat <<EOF > ${SHARED_DIR}/e2e_test.sh
#!/bin/bash
set -euo pipefail

export KUBECONFIG='${target_kubeconfig}'
export PULL_SECRET=\$(<${PULL_SECRET_FILE})
export TESTS_PULL_REF='${TESTS_PULL_REF}'
export REGISTRY_AUTH_FILE='${PULL_SECRET_FILE}'

mkdir tmp

podman run --quiet --rm -v ./tmp:/tmp:Z ${TESTS_PULL_REF} cp /usr/bin/openshift-tests /tmp/openshift-tests

sudo mv ./tmp/openshift-tests /usr/bin/openshift-tests
rm -rf tmp

mkdir ${remote_artifacts_dir}

# Run the conformance suite
openshift-tests run ${CONFORMANCE_SUITE} \
  --max-parallel-tests 15 \
  -o "${remote_artifacts_dir}/e2e.log" \
  --junit-dir "${remote_artifacts_dir}/junit" &
wait "\$!"
EOF

chmod +x ${SHARED_DIR}/e2e_test.sh

scp "${SSHOPTS[@]}" ${SHARED_DIR}/e2e_test.sh $ssh_host_ip:$remote_workdir

echo "Running the tests..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/e2e_test.sh"