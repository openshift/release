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
TARGET_VM_NAME=$(cat ${SHARED_DIR}/target_vm_name)
target_kubeconfig=${remote_workdir}/ib-orchestrate-vm/bip-orchestrate-vm/workdir-${TARGET_VM_NAME}/auth/kubeconfig

cat <<EOF > ${SHARED_DIR}/e2e_test_config.sh
#!/bin/bash
set -euo pipefail
export KUBECONFIG='${target_kubeconfig}'

date

# Configure the local image registry since the tests need it
oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed", "storage":{"emptyDir":{}}}}'

date

# Wait until the image registry change has been applied
until oc wait --timeout=10m co image-registry --for=condition=Available=true; do
  echo "Image Registry unavailable. Waiting a minute and then trying again..."
  sleep 1m
done

date

# Wait for operator rollouts
echo "Waiting for operators to update after registry update"
sleep 2m

# Loop until all operators are healthy
until [ -z "\$(oc get co -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Available" and .status!="True")) | .metadata.name')" ]; do
  echo "Operators still rolling out. Checking again in 1 minute"
  # Wait before checking again
  sleep 1m
done
echo "All operators are healthy."

date

echo "Waiting for the cluster to stabilize"
until oc wait --timeout=10m clusterversion version --for=condition=Failing=false; do
  echo "Cluster not yet stabilized. Waiting a minute and then trying again..."
  sleep 1m
done

date

EOF

chmod +x ${SHARED_DIR}/e2e_test_config.sh

scp "${SSHOPTS[@]}" ${SHARED_DIR}/e2e_test_config.sh $ssh_host_ip:$remote_workdir

echo "Configuring the registry operator..."
ssh "${SSHOPTS[@]}" $ssh_host_ip "${remote_workdir}/e2e_test_config.sh"
