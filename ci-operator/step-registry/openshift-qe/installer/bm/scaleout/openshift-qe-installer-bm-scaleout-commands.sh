#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
export LAB
LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud || cat ${SHARED_DIR}/lab_cloud)
export LAB_CLOUD

# Get the number of current dedicated worker nodes in the cluster
export KUBECONFIG=${SHARED_DIR}/kubeconfig
NUM_CURRENT_WORKER_NODES=$(oc get nodes | grep worker | grep -v -c master)
export NUM_CURRENT_WORKER_NODES

# Calculate the number of scaleout worker nodes
NUM_SCALEOUT_WORKER_NODES=$(($NUM_TARGET_WORKER_NODES-$NUM_CURRENT_WORKER_NODES))
export NUM_SCALEOUT_WORKER_NODES

echo "Starting SCALEOUT deployment on lab $LAB, cloud $LAB_CLOUD ..."
JETLAG_REPO_PATH=$(cat ${SHARED_DIR}/jetlag_repo)
export JETLAG_REPO_PATH

# Add Nodes to Worker Inventory for Scaleout deployment
scp -q ${SSH_ARGS} root@${bastion}:${JETLAG_REPO_PATH}/ansible/vars/all.yml /tmp/all-before-scaleout.yml
sed -i "s/^worker_node_count: [0-9]*/worker_node_count: $NUM_TARGET_WORKER_NODES/" /tmp/all-before-scaleout.yml

cat <<EOF >>/tmp/scale_out.yml
---
current_worker_count: $NUM_CURRENT_WORKER_NODES
scale_out_count: $NUM_SCALEOUT_WORKER_NODES
EOF

envsubst < /tmp/scale_out.yml > /tmp/scale_out-updated.yml

scp -q ${SSH_ARGS} /tmp/all-before-scaleout.yml root@${bastion}:${JETLAG_REPO_PATH}/ansible/vars/all.yml
scp -q ${SSH_ARGS} /tmp/scale_out-updated.yml root@${bastion}:${JETLAG_REPO_PATH}/ansible/vars/scale_out.yml

ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   cd ${JETLAG_REPO_PATH}
   source bootstrap.sh
   ansible-playbook ansible/create-inventory.yml | tee /tmp/ansible-create-inventory-$(date +%s)
   ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/mno-scale-out.yml -vvv | tee /tmp/ansible-mno-scaleout-$(date +%s)
   deactivate
   rm -rf .ansible
"
# Verification for Scale Out Deployment
oc version
oc get node
oc adm wait-for-stable-cluster --minimum-stable-period=${MINIMUM_STABLE_PERIOD} --timeout=${TIMEOUT}

# Validate that the current worker nodes count matches the target
FINAL_WORKER_COUNT=$(oc get nodes | grep worker | grep -v -c master)
export FINAL_WORKER_COUNT
echo "Final worker node count: $FINAL_WORKER_COUNT"
echo "Target worker node count: $NUM_TARGET_WORKER_NODES"

if [ "$FINAL_WORKER_COUNT" -eq "$NUM_TARGET_WORKER_NODES" ]; then
    echo "SUCCESS: Scale-out completed successfully. Current worker nodes ($FINAL_WORKER_COUNT) matches target ($NUM_TARGET_WORKER_NODES)"
    exit 0
else
    echo "FAILURE: Scale-out validation failed. Current worker nodes ($FINAL_WORKER_COUNT) does not match target ($NUM_TARGET_WORKER_NODES)"
    exit 1
fi