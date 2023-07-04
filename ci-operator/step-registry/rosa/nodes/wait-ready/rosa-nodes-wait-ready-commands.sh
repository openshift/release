#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

# Display details of machines and nodes
function listNodeDetails() {
    # Get current machine pools and status of nodes
    log "$(date) - List of machinesets"
    oc get machinesets -A
    log "$(date) - List of machines"
    oc get machines -A | cat -n
    log "$(date) - List of all worker only nodes, excluding infra"
    oc get nodes --no-headers -l node-role.kubernetes.io/worker,node-role.kubernetes.io/infra!= | cat -n

    # Get details of machines not in Running state
    for machine in $(oc get machine  -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-type=worker,machine.openshift.io/cluster-api-machine-type!=infra  --output jsonpath="{.items[?(@.status.phase!='Running')].metadata.name}"); do
      oc describe machine "$machine" -n openshift-machine-api
    done
    # Get details of nodes not in Ready state
    for node in $(oc get nodes --no-headers -l node-role.kubernetes.io/worker,node-role.kubernetes.io/infra!= --output jsonpath="{.items[?(@.status.conditions[-1].type!='Ready')].metadata.name}"); do
      oc describe node "$node"
    done
}

# Determine count of desired compute node count
function getDesiredComputeCount {
  compute_count=$(rosa describe cluster -c "$CLUSTER_ID"  -o json  |jq -r '.nodes.compute')
  if [ "$compute_count" = "null" ]; then 
    echo "--auto-scaling enabled, retrieving min_replicas count desired"
    desired_compute_count=$(rosa describe cluster -c "$CLUSTER_ID" -o json  | jq -r '.nodes.autoscale_compute.min_replicas') 
  else
    echo "--replicas set, retrieving replica count desired"
    desired_compute_count=$(rosa describe cluster -c "$CLUSTER_ID"  -o json  |jq -r '.nodes.compute')
  fi
  export desired_compute_count
  echo "Desired worker node count: $desired_compute_count"
}


# Get cluster 
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
echo "CLUSTER_ID is $CLUSTER_ID"

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

# Log in
ROSA_VERSION=$(rosa version)
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${ROSA_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
  rosa login --env "${ROSA_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

# Get desired compute node count
getDesiredComputeCount

# wait for all nodes to reach Ready=true to ensure that all machines and nodes came up, before we run
# any e2e tests that might require specific workload capacity.
echo "$(date) - waiting for all nodes to be ready in $READY_WAIT_TIMEOUT"
ret=0
oc wait nodes --all --for=condition=Ready=true --timeout="$READY_WAIT_TIMEOUT" || ret=$?

if [[ "$ret" == 0 ]]; then
    # Get count of worker only nodes in Ready state
    node_count="$(oc get nodes --no-headers -l node-role.kubernetes.io/worker,node-role.kubernetes.io/SchedulingDisabled!=,node-role.kubernetes.io/infra!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)"
    echo "Count of worker only nodes in Ready state: $node_count"

    # Check worker node count matches requested replica count
    if (( "$node_count" >= "$desired_compute_count" )); then
        echo "$(date): All $node_count worker nodes are ready and match desired $desired_compute_count node count."
    else
        echo "$(date): $node_count worker nodes are ready but does not match desired $desired_compute_count node count in $READY_WAIT_TIMEOUT."
        listNodeDetails
        exit 1
    fi
else
    echo "Some or all nodes failed to become ready in $READY_WAIT_TIMEOUT."
    listNodeDetails
    exit 1
fi