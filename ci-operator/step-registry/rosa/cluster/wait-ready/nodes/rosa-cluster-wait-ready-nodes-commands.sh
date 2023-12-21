#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}
set_proxy

# Display only node details 
function listNodeDetails() {
    echo "List node details"
    # Get current machine pools and status of nodes
    log "$(date) - List infra nodes"
    echo "oc get nodes --no-headers -l node-role.kubernetes.io/infra | cat -n"
    oc get nodes --no-headers -l node-role.kubernetes.io/infra | cat -n
    log "$(date) - List all worker nodes, excluding infra"
    echo "oc get nodes --no-headers -l node-role.kubernetes.io/worker,node-role.kubernetes.io/infra!= | cat -n"
    oc get nodes --no-headers -l node-role.kubernetes.io/worker,node-role.kubernetes.io/infra!= | cat -n

    # Get details of worker nodes not in Ready state
    log "$(date) - Worker nodes not in Ready state, if any"
    for node in $(oc get nodes --no-headers -l node-role.kubernetes.io/worker,node-role.kubernetes.io/infra!= --output jsonpath="{.items[?(@.status.conditions[-1].type!='Ready')].metadata.name}"); do
      oc describe node "$node"
    done
    log "$(date) - Finished printing details of all infra and worker nodes."
}

# Display details of machinesets and nodes for Classic Rosa cluster
function listMachineAndNodeDetails() {
    echo "List machine details"
    # Get current machinesets and machines 
    log "$(date) - List of machinesets"
    echo "oc get machinesets -n openshift-machine-api"
    oc get machinesets -n openshift-machine-api
    log "$(date) - List of machines"
    echo "oc get machines -n openshift-machine-api | cat -n"
    oc get machines -n openshift-machine-api | cat -n

    # Get details of worker machines not in Running state
    log "$(date) - Worker machines not in Running state, if any"
    for machine in $(oc get machine  -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-type=worker,machine.openshift.io/cluster-api-machine-type!=infra  --output jsonpath="{.items[?(@.status.phase!='Running')].metadata.name}"); do
      oc describe machine "$machine" -n openshift-machine-api
    done
    echo
    
    # Get details of all nodes 
    listNodeDetails
}

# Display Machine Config Pool details
function listMachineConfigPoolDetails() {
    log "$(date) - List machine config pools"
    echo "oc get mcp"
    oc get mcp
}

# List details of machinesets, machines and nodes depending on Classic Rosa or HCP cluster
function listDetails() {
  if [ "$is_hcp_cluster" = "false" ]; then
    echo "Listing machine pool config, machine and node details"
    listMachineConfigPoolDetails
    listMachineAndNodeDetails
  else
    echo "Listing node details only"
    listNodeDetails
  fi
}

# Function introducing sleep and wait for worker nodes to become Ready state
function waitForReady() {
    echo "Wait for all nodes to be Ready"

    # Query the node state until all of the nodes are ready
    FINAL_NODE_STATE="Pass"
    max_attempts=60 # Max of 60 attempts with 30 sec wait time in between, for total of 60 min
    retry_api_count=0
    max_retry_api_attempts=5
    # Nodes can cycle and may be all "Ready" during a check but not a moment later
    # We look for X number of successful attempts in a row
    successful_attempts=0
    desired_successful_attempts=3
    for i in $( seq $max_attempts ); do
        NODE_STATE="$(oc get nodes || echo "ERROR")"
        if [[ ${NODE_STATE} == *"NotReady"*  || ${NODE_STATE} == *"SchedulingDisabled"* ]]; then
            FINAL_NODE_STATE="Fail"
            echo "Not all nodes have finished restarting - waiting for 30 seconds, attempt ${i}"
	    successful_attempts=0
        elif [[ ${NODE_STATE} == "ERROR" ]]; then
     	    retry_api_count=$((retry_api_count+1))
	    successful_attempts=0
            if [[ "$retry_api_count" -gt "$max_retry_api_attempts" ]]; then
                FINAL_NODE_STATE="Fail"
                break
            fi
        else
	    # Infra are not counted for non-HCP clusters
	    if [[ "$HOSTED_CP" == "false" ]]; then
		node_count="$(oc get nodes --no-headers -l node-role.kubernetes.io/infra!=,node-role.kubernetes.io/worker --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)"
	    else
		node_count="$(oc get nodes --no-headers -l node-role.kubernetes.io/worker --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)"
            fi
            if [[ "$node_count" -ge "$1" ]]; then
	        if [[ "$successful_attempts" -lt "$desired_successful_attempts" ]]; then
   		    successful_attempts=$((successful_attempts+1))
	            echo "Successful attempts at Nodes being Ready in a row: $successful_attempts Want: $desired_successful_attempts"
	        else
                    echo "All nodes are ready to run workloads."
                    FINAL_NODE_STATE="Pass"
                    break
	        fi
            else
                echo "Only $node_count/$1 worker nodes are ready."
	        successful_attempts=0
            fi
        fi
        export FINAL_NODE_STATE
        sleep 60
    done

    if [[ ${FINAL_NODE_STATE} == *"Fail"* ]]; then
        echo "Waited for 30 min for nodes to become Ready. Some or all nodes are NotReady or have SchedulingDisabled. Exiting test case execution!"
        listDetails
        exit 1
    fi
}

# Determine count of desired compute node count
function getDesiredComputeCount {
  compute_count=$(rosa describe cluster -c "$CLUSTER_ID"  -o json  |jq -r '.nodes.compute')
  if [[ "$compute_count" = "null" ]]; then 
    echo "--auto-scaling enabled, retrieving min_replicas count desired"
    desired_compute_count=$(rosa describe cluster -c "$CLUSTER_ID" -o json  | jq -r '.nodes.autoscale_compute.min_replicas') 
  else
    echo "--auto-scaling disabled, --replicas set, retrieving replica count desired"
    desired_compute_count=$(rosa describe cluster -c "$CLUSTER_ID"  -o json  |jq -r '.nodes.compute')
  fi
  export desired_compute_count
  echo "Total desired node count: $desired_compute_count"
}

# Determine if node count needs to be revised due to day 2 op workaround for medium+ sized clusters
function fixNodeScaling {
  machine_pool=$(rosa list machinepool -c "$CLUSTER_ID" -o json)
  if [[ "$HOSTED_CP" == "false" ]] && [[ `echo "$machine_pool" | jq -e '.[] | has("autoscaling")'` == "true" ]]; then
    if [[ "$ENABLE_AUTOSCALING" == "true" ]]; then
      if [[ `echo "$machine_pool" | jq -r '.[].autoscaling.min_replicas'` -ne ${MIN_REPLICAS} ]]; then
        rosa edit machinepool -c "$CLUSTER_ID" worker --min-replicas "$MIN_REPLICAS"
      fi
    else
      rosa edit machinepool -c "$CLUSTER_ID" worker --enable-autoscaling=false --replicas "$REPLICAS"
    fi
  fi
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
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

# Check if this is a HCP cluster
is_hcp_cluster="$(rosa describe cluster -c "$CLUSTER_ID" -o json  | jq -r ".hypershift.enabled")"
log "hypershift.enabled is set to $is_hcp_cluster"

# Check if we modified the node counts to reduce day 2 op time and fix as necessary
fixNodeScaling

# Get desired compute node count
getDesiredComputeCount

ret=0
echo "Wait for all nodes to be ready and schedulable."
waitForReady "$desired_compute_count" || ret=$?

if [[ "$ret" == 0 ]]; then
    # Get count of worker only nodes in Ready state
    node_count="$(oc get nodes --no-headers -l node-role.kubernetes.io/worker,node-role.kubernetes.io/infra!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)"
    echo "Count of worker only nodes in Ready state: $node_count"
    
    # Check worker node count matches requested replica count
    if (( "$node_count" >= "$desired_compute_count" )); then
        echo "$(date): All $node_count worker nodes are ready and match desired $desired_compute_count node count."
    else
        echo "$(date): $node_count worker nodes are ready but does not match desired $desired_compute_count node count."
    fi        
    listDetails
else
    echo "Failed to execute script, waitForReady, to check node status. Return code: $ret."
    echo "Exiting test!"
    exit 1
fi
