#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

function getDesiredInfraCount() {
  desired_infra_count=${MP_REPLICAS}
  echo "Desired Infra node count: $desired_infra_count"
}

# Display only Infra details 
function listNodeDetails() {
    echo "List node details"
    # Get current machine pools and status of nodes
    log "$(date) - List infra nodes"
    echo "oc get nodes --no-headers -l node-role.kubernetes.io/infra | cat -n"
    oc get nodes --no-headers -l node-role.kubernetes.io/infra | cat -n

    # Get details of Infra nodes not in Ready state
    log "$(date) - Infra nodes not in Ready state, if any"
    for node in $(oc get nodes --no-headers -l node-role.kubernetes.io/infra --output jsonpath="{.items[?(@.status.conditions[-1].type!='Ready')].metadata.name}"); do
      oc describe node "$node"
    done
    log "$(date) - Finished printing details of all infra nodes."
}

function checkForInfraReady() {
    node_count="$(oc get nodes --no-headers -l node-role.kubernetes.io/infra --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)"
    echo "Count of infra nodes in Ready state: $node_count"
    
    if (( "$node_count" >= "$1" )); then
        log "$(date): All $node_count Infra nodes are ready and match desired $1 infra count."
    else
        log "$(date): Only $node_count Infra nodes are ready but does not match desired $1 node count."
        exit 1
    fi
    listNodeDetails
}

function rebalanceInfra() {
    if [[ $1 == "prometheus-k8s" ]] ; then
        log "$(date) - Initiate migration of prometheus componenets to infra nodepools"
        oc get pods -n openshift-monitoring -o wide | grep prometheus-k8s
        oc get sts prometheus-k8s -n openshift-monitoring
        
        log "$(date) - Restart stateful set pods"
        echo "rollout restart -n openshift-monitoring statefulset/prometheus-k8s"
        oc rollout restart -n openshift-monitoring statefulset/prometheus-k8s 
        
        log "$(date) - Wait till they are completely restarted"
        oc rollout status -n openshift-monitoring statefulset/prometheus-k8s
        
        log "$(date) - Check pods status again and the hosting nodes"
        oc get pods -n openshift-monitoring -o wide | grep prometheus-k8s
    else
        log "$(date) - Initiate migration of ingress router-default pods to infra nodepools"
        echo "Add toleration to use infra nodes"

        oc patch ingresscontroller -n openshift-ingress-operator default --type merge --patch  '{"spec":{"nodePlacement":{"nodeSelector":{"matchLabels":{"node-role.kubernetes.io/infra":""}},"tolerations":[{"effect":"NoSchedule","key":"node-role.kubernetes.io/infra","operator":"Exists"}]}}}'
        
        echo "Wait till it gets rolled out"
        sleep 60

        oc get pods -n openshift-ingress -o wide
    fi    
}

function checkInfra() {
    TRY=0
    while [ $TRY -le 3 ]; do # Attempts three times to migrate pods
        FLAG_ERROR=""
        rebalanceInfra $1
        for node in $(oc get pods -n "$2" -o wide | grep -i "$1" | grep -i running | awk '{print$7}');
        do
            if [[ $(oc get nodes --no-headers -l node-role.kubernetes.io/infra | awk '{print$1}' | grep $node) != "" ]]; then
                log "$(date) - $node is an infra node"
            else
                log "$(date) - $1 pod on $node is not an infra node, retrying"
                FLAG_ERROR=true
            fi
        done
        if [[ $FLAG_ERROR == "" ]]; then return 0; else TRY=$((TRY+1)); fi
    done
    echo "Failed to move $1 pods in $2 namespace"
    exit 1
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

if [[ "$is_hcp_cluster" == "true" ]]; then
  getDesiredInfraCount

  if [[ "$desired_infra_count" -gt 0 ]]; then
    echo "Check if all Infra nodes are ready and schedulable."
    checkForInfraReady "$desired_infra_count"

    echo "Re-balance infra components"
    checkInfra "prometheus-k8s" "openshift-monitoring"
    checkInfra "router" "openshift-ingress"
  fi
else
  echo "$CLUSTER_ID is not an Hostedcluster, skipping this task"
  exit 0
fi