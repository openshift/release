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

if [[ "$TEST_CLUSTER" != "seed" && "$TEST_CLUSTER" != "target" ]]; then
  echo "TEST_CLUSTER is an invalid value: '${TEST_CLUSTER}'"
  exit 1
fi

TEST_VM_NAME="$(cat ${SHARED_DIR}/${TEST_CLUSTER}_vm_name)"

test_kubeconfig=${remote_workdir}/ib-orchestrate-vm/bip-orchestrate-vm/workdir-${TEST_VM_NAME}/auth/kubeconfig
remote_artifacts_dir=${remote_workdir}/artifacts

cat <<EOF > ${SHARED_DIR}/e2e_test.sh
#!/bin/bash
set -euo pipefail

export KUBECONFIG='${test_kubeconfig}'
export PULL_SECRET=\$(<${PULL_SECRET_FILE})
export TESTS_PULL_REF='${TESTS_PULL_REF}'
export REGISTRY_AUTH_FILE='${PULL_SECRET_FILE}'

mkdir tmp

podman run --quiet --rm -v ./tmp:/tmp:Z ${TESTS_PULL_REF} cp /usr/bin/openshift-tests /tmp/openshift-tests

sudo mv ./tmp/openshift-tests /usr/bin/openshift-tests
rm -rf tmp

mkdir ${remote_artifacts_dir}

if [[ "${TEST_VM_NAME}" = "target-sno-node" ]]; then
    sudo virsh shutdown seed-sno-node
fi

if [[ -n "${TEST_SKIPS}" ]]; then
    TESTS="\$(openshift-tests run --dry-run "${CONFORMANCE_SUITE}")" &&
    echo "\${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests &&
    echo "Skipping tests:" &&
    echo "\${TESTS}" | grep "${TEST_SKIPS}" || { exit_code=$?; echo 'Error: no tests were found matching the TEST_SKIPS regex:'; echo "$TEST_SKIPS"; return \$exit_code; } &&
    TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
fi &&

set -x &&
openshift-tests run "${CONFORMANCE_SUITE}" \${TEST_ARGS:-} \
    -o "${remote_artifacts_dir}/e2e.log" \
    --junit-dir "${remote_artifacts_dir}/junit" &
wait "\$!" &&
set +x
exit_code=\$?

if [[ "${TEST_VM_NAME}" = "target-sno-node" ]]; then
    sudo virsh start seed-sno-node
    oc --kubeconfig=\${remote_work_dir}/ib-orchestrate-vm/bip-orchestrate-vm/workdir-seed/auth/kubeconfig \
      adm wait-for-stable-cluster \
      --minimum-stable-period=2m \
      --timeout=5m
fi

return \${exit_code}

EOF

chmod +x ${SHARED_DIR}/e2e_test.sh

scp "${SSHOPTS[@]}" ${SHARED_DIR}/e2e_test.sh $ssh_host_ip:$remote_workdir

echo "Running the tests..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/e2e_test.sh"
