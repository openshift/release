#!/bin/bash

export LC_CTYPE=C
set -o nounset
set -o errexit
set -o pipefail

echo "get mgmt cluster's kubeconfig"
export KUBECONFIG=${SHARED_DIR}/kubeconfig
if test -s "${SHARED_DIR}/mgmt_kubeconfig" ; then
  export KUBECONFIG=${SHARED_DIR}/mgmt_kubeconfig
fi

# get one worker node
node_name=$(oc get no -lnode-role.kubernetes.io/worker --ignore-not-found -ojsonpath='{.items[].metadata.name}')
if [[ -n ${node_name} ]] ; then
  instance_id=$(aws ec2 describe-instances --filters "Name=private-dns-name,Values=${node_name}" --query "Reservations[].Instances[].InstanceId" --output text)
fi

echo "stop worker node ${node_name} with instance ID ${instance_id}"
aws ec2 stop-instances --instance-ids ${instance_id}
echo "wait until the worker node ${node_name} NotReady"
oc wait no ${node_name} --for=condition=NotReady

status=$(aws ec2 describe-instances --instance-ids ${instance_id} --query "Reservations[].Instances[].State.Name" --output text)
echo "now worker node ${instance_id} status is ${status}"
if [[ "${status}" != "stopped" ]] ; then
  echo "worker node ${node_name} ${instance_id} is not in the stopped status"
  exit 1
fi

echo ${node_name} > "${SHARED_DIR}/hypershift-dr-worker-node-name"
echo ${instance_id} > "${SHARED_DIR}/hypershift-dr-worker-instance-id"

# tag/start hypeshift dr mode, because network CO will not ready in the hosted cluster in this mode
echo "true" > "${SHARED_DIR}/hypershift-dr-mode"
