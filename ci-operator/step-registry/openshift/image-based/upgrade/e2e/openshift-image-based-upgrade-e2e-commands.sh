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
PULL_SECRET_FILE="/var/run/pull-secret/.dockerconfigjson"
PULL_SECRET=$(cat ${PULL_SECRET_FILE})

TARGET_VM_NAME=$(cat ${SHARED_DIR}/target_vm_name)
target_kubeconfig=${remote_workdir}/ib-orchestrate-vm/bip-orchestrate-vm/workdir-${TARGET_VM_NAME}/auth/kubeconfig
remote_artifacts_dir=${remote_workdir}/artifacts

cat <<EOF > ${SHARED_DIR}/e2e_test.sh
#!/bin/bash
set -xeuo pipefail

export KUBECONFIG='${target_kubeconfig}'
export PULL_SECRET='${PULL_SECRET}'
export TESTS_PULL_REF='${TESTS_PULL_REF}'

echo '${PULL_SECRET}' > ${remote_workdir}/.dockerconfig.json
export REGISTRY_AUTH_FILE='${remote_workdir}/.dockerconfig.json'

# Configure the local image registry since the tests need it
oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed", "storage":{"emptyDir":{}}}}'

mkdir tmp

podman run --quiet --rm -v ./tmp:/tmp:Z ${TESTS_PULL_REF} cp /usr/bin/openshift-tests /tmp/openshift-tests

sudo mv ./tmp/openshift-tests /usr/bin/openshift-tests
rm -rf tmp

mkdir ${remote_artifacts_dir}

# Run the conformance suite
openshift-tests run ${CONFORMANCE_SUITE} \
  -o "${remote_artifacts_dir}/e2e.log" \
  --junit-dir "${remote_artifacts_dir}/junit" &
wait "\$!"
EOF

chmod +x ${SHARED_DIR}/e2e_test.sh

scp "${SSHOPTS[@]}" ${SHARED_DIR}/e2e_test.sh $ssh_host_ip:$remote_workdir

echo "Running the tests..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/e2e_test.sh"