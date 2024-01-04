#!/bin/bash

export LC_CTYPE=C
set -o nounset
set -o errexit
set -o pipefail

if [[ ! -f "${SHARED_DIR}/hypershift-dr-worker-node-name" ]] ; then
  echo "${SHARED_DIR}/hypershift-dr-worker-node-name" file not found, skip step
  exit 0
fi

echo "get mgmt cluster's kubeconfig"
export KUBECONFIG=${SHARED_DIR}/kubeconfig
if test -s "${SHARED_DIR}/mgmt_kubeconfig" ; then
  export KUBECONFIG=${SHARED_DIR}/mgmt_kubeconfig
fi

node_name=$(cat "${SHARED_DIR}/hypershift-dr-worker-node-name")
instance_id=$(cat "${SHARED_DIR}/hypershift-dr-worker-instance-id")

status=$(oc get no ${node_name} -ojsonpath='{.status.conditions[?(@.type=="Ready")].status}')
if [[ "X${status}" == "X" || "${status}" == "True"  ]] ; then
  echo "worker node ${node_name} could not found or it has been recovered, skip this step"
  exit 0
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

echo "start worker node ${node_name} with instance ID ${instance_id}"
aws ec2 start-instances --instance-ids ${instance_id}
echo "wait until the worker node ${node_name} Ready"
oc wait no ${node_name} --for=condition=Ready --timeout=10m

status=$(aws ec2 describe-instances --instance-ids ${instance_id} --query "Reservations[].Instances[].State.Name" --output text)
echo "now worker node ${instance_id} status is ${status}"
if [[ "${status}" != "running" ]] ; then
  echo "worker node ${node_name} ${instance_id} is not in the running status"
  exit 1
fi


# check hcp
HYPERSHIFT_NAMESPACE=$(oc get hostedclusters --ignore-not-found -A '-o=jsonpath={.items[0].metadata.namespace}')
if [ -z "$HYPERSHIFT_NAMESPACE" ]; then
    echo "Could not find HostedCluster, which is not valid."
    return 1
fi
CLUSTER_NAME=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o=jsonpath='{.items[0].metadata.name}')
oc wait deploy -n ${HYPERSHIFT_NAMESPACE}-${CLUSTER_NAME} --for=condition=Available --all --timeout=120s
oc wait pod -n ${HYPERSHIFT_NAMESPACE}-${CLUSTER_NAME} --for=condition=Ready --all
echo "All pods are in the expected state."

# switch to hosted cluster kubeconfig
if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  echo "could not find nested_kubeconfig, exit"
  exit 1
fi
export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
oc wait co --all --for='condition=AVAILABLE=True' --timeout=120s
oc wait co --all --for='condition=PROGRESSING=False' --timeout=120s
oc wait clusterversion version --for='condition=PROGRESSING=False' --timeout=10s
oc wait clusterversion version --for='condition=AVAILABLE=True' --timeout=10s
# end of hypershift dr mode
echo "false" > "${SHARED_DIR}/hypershift-dr-mode"

