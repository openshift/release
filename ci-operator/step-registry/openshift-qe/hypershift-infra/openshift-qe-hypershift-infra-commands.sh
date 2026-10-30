#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

function oc_with_retry() {
    local max_retries="${OC_MAX_RETRIES:-5}"
    local retry_wait="${OC_RETRY_WAIT:-10}"
    local attempt=1

    while (( attempt <= max_retries )); do
        if oc "$@"; then
            return 0
        fi
        if (( attempt == max_retries )); then
            echo "oc command failed after ${max_retries} attempts: oc $*" >&2
            return 1
        fi
        echo "oc command failed (attempt ${attempt}/${max_retries}), retrying in ${retry_wait}s: oc $*" >&2
        sleep "$retry_wait"
        attempt=$(( attempt + 1 ))
    done
    return 1
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
    oc_with_retry get nodes --no-headers -l node-role.kubernetes.io/infra | cat -n

    # Get details of Infra nodes not in Ready state
    log "$(date) - Infra nodes not in Ready state, if any"
    for node in $(oc_with_retry get nodes --no-headers -l node-role.kubernetes.io/infra --output jsonpath="{.items[?(@.status.conditions[-1].type!='Ready')].metadata.name}"); do
      oc_with_retry describe node "$node"
    done
    log "$(date) - Finished printing details of all infra nodes."
}

function checkForInfraReady() {
    local desired_count="$1"
    local timeout="${READY_WAIT_TIMEOUT:-10m}"
    local timeout_seconds
    local timeout_value
    local timeout_unit
    local deadline
    local ready_nodes
    local node_count

    if [[ "$timeout" =~ ^([0-9]+)([smh])?$ ]]; then
        timeout_value="${BASH_REMATCH[1]}"
        timeout_unit="${BASH_REMATCH[2]}"
        case "$timeout_unit" in
            h) timeout_seconds=$(( timeout_value * 3600 )) ;;
            m) timeout_seconds=$(( timeout_value * 60 )) ;;
            s|'') timeout_seconds=$timeout_value ;;
        esac
    else
        log "Invalid READY_WAIT_TIMEOUT value: ${timeout}"
        exit 1
    fi

    deadline=$(( $(date +%s) + timeout_seconds ))
    while true; do
        if ready_nodes=$(oc_with_retry get nodes --no-headers -l node-role.kubernetes.io/infra --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}"); then
            node_count=$(wc -w <<< "$ready_nodes" | xargs)
        else
            node_count=0
            log "$(date): Failed to query infra nodes; retrying."
        fi
        echo "Count of infra nodes in Ready state: $node_count/$desired_count"

        if (( node_count >= desired_count )); then
            log "$(date): All $node_count Infra nodes are ready and match desired $desired_count infra count."
            listNodeDetails
            return 0
        fi

        if (( $(date +%s) >= deadline )); then
            log "$(date): Only $node_count Infra nodes are ready after waiting ${timeout}; desired $desired_count."
            listNodeDetails
            exit 1
        fi

        log "$(date): Waiting for infra nodes to become ready; retrying in 30 seconds."
        sleep 30
    done
}

function rebalanceInfra() {
    if [[ $1 == "prometheus-k8s" ]] ; then
        log "$(date) - Initiate migration of prometheus to infra nodepools"
        oc_with_retry get pods -n openshift-monitoring -o wide | grep prometheus-k8s
        oc_with_retry get sts prometheus-k8s -n openshift-monitoring

        log "$(date) - Apply cluster-monitoring-config to move prometheus to infra nodes"
        # Note: Fresh ROSA HCP clusters don't have cluster-monitoring-config by default.
        # Safe to create/replace for single-use CI clusters. If running against reused
        # clusters with existing monitoring config, this would overwrite retention/resources.
        # Only moving prometheusK8s as it's the resource-intensive component; other monitoring
        # components consume minimal resources and can remain on worker nodes.
        monitoring_config_file=$(mktemp)
        cat > "$monitoring_config_file" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |+
    prometheusK8s:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
        - effect: "NoSchedule"
          key: "node-role.kubernetes.io/infra"
          operator: "Exists"
EOF
        oc_with_retry apply -f "$monitoring_config_file" || {
            rm -f "$monitoring_config_file"
            exit 1
        }
        rm -f "$monitoring_config_file"

        log "$(date) - Wait for cluster-monitoring-operator to reconcile the configuration"
        RECONCILED=false
        for i in {1..30}; do
            if oc_with_retry get sts prometheus-k8s -n openshift-monitoring -o json | \
                jq -e '.spec.template.spec.nodeSelector["node-role.kubernetes.io/infra"] == "" and any(.spec.template.spec.tolerations[]?; .key == "node-role.kubernetes.io/infra" and .operator == "Exists" and .effect == "NoSchedule")' >/dev/null; then
                RECONCILED=true
                log "$(date) - StatefulSet reconciled with infra nodeSelector and tolerations"
                break
            fi
            [[ $((i % 6)) -eq 0 ]] && log "$(date) - Still waiting for reconciliation... ($i/30)"
            sleep 10
        done
        if [[ "${RECONCILED}" != "true" ]]; then
            log "$(date) - ERROR: cluster-monitoring-operator did not update prometheus-k8s placement"
            log "Current StatefulSet spec:"
            oc_with_retry get sts prometheus-k8s -n openshift-monitoring -o json | jq '.spec.template.spec | {nodeSelector, tolerations}'
            exit 1
        fi

        log "$(date) - Restart stateful set pods"
        echo "rollout restart -n openshift-monitoring statefulset/prometheus-k8s"
        oc_with_retry rollout restart -n openshift-monitoring statefulset/prometheus-k8s

        log "$(date) - Wait till they are completely restarted"
        oc_with_retry rollout status -n openshift-monitoring statefulset/prometheus-k8s

        log "$(date) - Verify prometheus pods are running on infra nodes"
        # Wait up to 2 minutes for pods to be scheduled on infra nodes
        RETRY=0
        MAX_RETRIES=12
        VERIFY_SUCCESS=false
        while [ $RETRY -lt $MAX_RETRIES ]; do
            ALL_ON_INFRA=true
            for node in $(oc_with_retry get pods -n openshift-monitoring -o wide | grep -i "prometheus-k8s-" | grep -i running | awk '{print$7}'); do
                if [[ $(oc_with_retry get nodes --no-headers -l node-role.kubernetes.io/infra | awk '{print$1}' | grep -w "$node") != "" ]]; then
                    log "$(date) - prometheus pod on $node (infra node) ✓"
                else
                    log "$(date) - WARNING: prometheus pod on $node is NOT an infra node"
                    ALL_ON_INFRA=false
                fi
            done

            if [ "$ALL_ON_INFRA" = true ]; then
                log "$(date) - All prometheus-k8s pods are on infra nodes ✓"
                VERIFY_SUCCESS=true
                break
            else
                RETRY=$((RETRY+1))
                log "$(date) - Retry $RETRY/$MAX_RETRIES: Waiting for prometheus pods to move to infra nodes..."
                sleep 10
            fi
        done

        if [ "$VERIFY_SUCCESS" = false ]; then
            log "$(date) - ERROR: Prometheus pods failed to move to infra nodes after $MAX_RETRIES attempts"
            oc_with_retry get pods -n openshift-monitoring -o wide | grep prometheus-k8s
            exit 1
        fi

        log "$(date) - Check pods status again and the hosting nodes"
        oc_with_retry get pods -n openshift-monitoring -o wide | grep prometheus-k8s
    else
        log "$(date) - Initiate migration of ingress router-default pods to infra nodepools"
        echo "Add toleration to use infra nodes"

        oc_with_retry patch ingresscontroller -n openshift-ingress-operator default --type merge --patch  '{"spec":{"nodePlacement":{"nodeSelector":{"matchLabels":{"node-role.kubernetes.io/infra":""}},"tolerations":[{"effect":"NoSchedule","key":"node-role.kubernetes.io/infra","operator":"Exists"}]}}}'
        
        echo "Wait till it gets rolled out"
        sleep 60

        oc_with_retry get pods -n openshift-ingress -o wide
    fi    
}

function checkInfra() {
    TRY=0
    while [ $TRY -le 3 ]; do # Attempts three times to migrate pods
        FLAG_ERROR=""
        rebalanceInfra $1
        for node in $(oc_with_retry get pods -n "$2" -o wide | grep -i "$1" | grep -i running | awk '{print$7}');
        do
            if [[ $(oc_with_retry get nodes --no-headers -l node-role.kubernetes.io/infra | awk '{print$1}' | grep $node) != "" ]]; then
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

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

ROSA_SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
ROSA_SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")

if [[ -n "${ROSA_SSO_CLIENT_ID}" && -n "${ROSA_SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id "${ROSA_SSO_CLIENT_ID}" --client-secret "${ROSA_SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
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
    # checkInfra "prometheus-k8s" "openshift-monitoring"  # turned off validation due to OCPBUGS-27216
    rebalanceInfra "prometheus-k8s"
    checkInfra "router" "openshift-ingress"
  fi
else
  echo "$CLUSTER_ID is not an Hostedcluster, skipping this task"
  exit 0
fi
