#!/bin/bash

set -euo pipefail

# ====== Logging helpers ======
log()   { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

# Retry function that executes a given check function multiple times until it succeeds or reaches the maximum number of retries.
# Parameters:
#   - check_func: The function to be executed and checked for success.
# Returns:
#   - 0 if the check function succeeds within the maximum number of retries.
#   - 1 if the check function fails to succeed within the maximum number of retries.
# Usage example:
retry() {
    local check_func=$1
    local max_retries=10
    local retry_delay=30
    local retries=0

    while (( retries < max_retries )); do
        if $check_func; then
            log "Check '$check_func' succeeded."
            return 0
        fi

        (( retries++ ))
        if (( retries < max_retries )); then
            warn "Check '$check_func' failed. Retrying in $retry_delay seconds... (Attempt ${retries}/${max_retries})"
            sleep $retry_delay
        fi
    done

    error "Check '$check_func' failed after $max_retries attempts."
    return 1
}

# ====== Cluster Info ======
print_clusterversion() {
    local clusterversion
    clusterversion=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
    log "Cluster version: $clusterversion"
}

# ====== Capability Checks ======
is_disabled_capability() {
    local component="$1"
    local status_caps spec_caps enabled_caps

    status_caps=$(oc get clusterversion -o=jsonpath='{.items[*].status.capabilities.enabledCapabilities}')
    spec_caps=$(oc get clusterversion -o=jsonpath='{.items[*].spec.capabilities.additionalEnabledCapabilities}')

    log "Cluster enabled capabilities (status): $status_caps"
    log "Additional enabled capabilities (spec): $spec_caps"

    enabled_caps="$(echo "$status_caps $spec_caps" | tr ' ' '\n' | tr '[:upper:]' '[:lower:]')"

    if echo "$enabled_caps" | grep -qw "$(echo "$component" | tr '[:upper:]' '[:lower:]')"; then
        return 1 # It is enabled, so "is_disabled" is false
    fi
    return 0 # It is not in the enabled list, so "is_disabled" is true
}

get_disabled_capabilities() {
    local disabled_caps=""
    if [[ -n "${HC_DISABLED_CAPS:-}" ]]; then
        disabled_caps="$HC_DISABLED_CAPS"
    fi
    echo "$disabled_caps" | tr ',' '\n' | tr '[:upper:]' '[:lower:]' | sed '/^$/d'
}

check_disabled_capability() {
    log "Checking for disabled capabilities..."
    mapfile -t caps < <(get_disabled_capabilities)
    if [[ ${#caps[@]} -eq 0 ]]; then
        warn "No disabled capabilities specified in HC_DISABLED_CAPS. Skipping check."
        return 0
    fi

    for cap in "${caps[@]}"; do
        if ! is_disabled_capability "$cap"; then
            error "Capability \"$cap\" is not disabled but should be."
            return 1
        fi
        log "Verified capability is disabled: $cap"
    done
    log "✅ All specified capabilities are disabled as expected."
}


# This function checks the status of control plane pods in a HostedCluster.
# It first gets the name of the cluster using the "oc get hostedclusters" command.
# It then reads the output of "oc get pod" command in the corresponding HostedCluster namespace and checks if the status is "Running" or "Completed".
# If any pod is not in the expected state, it prints an error message and returns 1. Otherwise, it returns 0.
check_control_plane_pod_status() {
    local ns cluster_name control_plane_ns unhealthy_pods
    log "Checking control plane pod status..."
    ns=$(oc get hostedclusters -A -o=jsonpath='{.items[0].metadata.namespace}')
    if [[ -z "$ns" ]]; then
        error "Could not find HostedCluster namespace."
        return 1
    fi
    cluster_name=$(oc get hostedclusters -n "$ns" -o=jsonpath='{.items[0].metadata.name}')
    control_plane_ns="${ns}-${cluster_name}"
    
    log "Checking pods in control plane namespace: ${control_plane_ns}"
    unhealthy_pods=$(oc get pods -n "${control_plane_ns}" -o 'jsonpath={range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' | grep -vE " (Running|Succeeded)$" || true)

    if [[ -n "$unhealthy_pods" ]]; then
        error "Found unhealthy control plane pods:"
        printf "NAMESPACE\tNAME\tSTATUS\n"
        echo "$unhealthy_pods" | awk '{printf "%s\t%s\t%s\n", $1, $2, $3}'
        return 1
    fi
    log "✅ All control plane pods are healthy."
    return 0
}

# This function checks the status of all pods in all namespaces.
# It reads the output of "oc get pod" command and checks if the status is "Running" or "Completed".
# If any pod is not in the expected state, it prints an error message and returns 1. Otherwise, it returns 0.
check_pod_status() {
    log "Checking all pod statuses..."
    local unhealthy_pods
    unhealthy_pods=$(oc get pods --all-namespaces -o 'jsonpath={range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' | grep -v "open-cluster-management-agent-addon" | grep -vE " (Running|Succeeded)$" || true)
    
    # Ignore some pods for ROSA HCP as they can take a long time to recover.
    unhealthy_pods=$(echo "$unhealthy_pods" | grep -v "azure-path-fix" | grep -v "osd-delete-backplane" | grep -v "osd-cluster-ready" || true)

    if [[ -n "$unhealthy_pods" ]]; then
        error "Found unhealthy pods:"
        printf "NAMESPACE\tNAME\tSTATUS\n"
        echo "$unhealthy_pods" | awk '{printf "%s\t%s\t%s\n", $1, $2, $3}'
        return 1
    fi
    log "✅ All pods are healthy."
    return 0
}

# This function checks the status of all cluster operators.
# It reads the output of "oc get clusteroperators" command and checks if the conditions are in the expected state.
# If any cluster operator is not in the expected state, it prints an error message and returns 1. Otherwise, it returns 0.
check_cluster_operators() {
    log "Checking cluster operator status..."
    local unhealthy_co=false
    
    # Using a temp file to avoid issues with read and subshells
    local co_output
    co_output=$(mktemp)
    oc get co -o custom-columns=NAME:.metadata.name,AVAILABLE:'{.status.conditions[?(@.type=="Available")].status}',PROGRESSING:'{.status.conditions[?(@.type=="Progressing")].status}',DEGRADED:'{.status.conditions[?(@.type=="Degraded")].status}' --no-headers > "$co_output"

    while read -r name available progressing degraded; do
        if [[ "$available" != "True" ]]; then
            warn "ClusterOperator '$name' is not Available (Available=$available)"
            unhealthy_co=true
        fi
        if [[ "$progressing" != "False" ]]; then
            warn "ClusterOperator '$name' is Progressing (Progressing=$progressing)"
            unhealthy_co=true
        fi
        if [[ "$degraded" != "False" ]]; then
            warn "ClusterOperator '$name' is Degraded (Degraded=$degraded)"
            unhealthy_co=true
        fi
    done < "$co_output"
    rm "$co_output"

    if [[ "$unhealthy_co" == true ]]; then
        error "One or more ClusterOperators are not healthy. Current status:"
        oc get co
        return 1
    fi
    log "✅ All ClusterOperators are healthy."
    return 0
}

# This function checks the status of all nodes.
# It reads the output of "oc get node" command and checks if the status is "Ready".
# If any node is not in the expected state, it prints an error message and returns 1. Otherwise, it returns 0.
check_node_status() {
    log "Checking node status..."
    local unhealthy_nodes
    unhealthy_nodes=$(oc get nodes --no-headers | grep -v " Ready " || true)
    if [[ -n "$unhealthy_nodes" ]]; then
        error "Found nodes that are not Ready:"
        echo "$unhealthy_nodes"
        return 1
    fi
    log "✅ All nodes are Ready."
    return 0
}

# This function checks the KMS encryption configuration based on the mgmt kubeconfig
# only for aws platform
check_kms_encryption_config() {
  log "Checking KMS encryption config..."
  if [[ "${HYPERSHIFT_DISK_ENCRYPTION:-false}" == "true" ]] ; then
      local kms_key_arn_file="${SHARED_DIR}/aws_kms_key_arn"
      if [[ -f "$kms_key_arn_file" ]] ; then
          local KMS_KEY_ARN
          KMS_KEY_ARN=$(cat "$kms_key_arn_file")
          if [[ -z "$KMS_KEY_ARN" ]]; then
              error "KMS key ARN file is empty."
              return 1
          fi

          local ns
          ns=$(oc get hostedclusters -A -o=jsonpath='{.items[0].metadata.namespace}')
          if [ -z "$ns" ]; then
              error "Could not find HostedCluster namespace."
              return 1
          fi

          # check nodepool spec
          local key_arn
          key_arn=$(oc get nodepool -n "$ns" -o=jsonpath='{.items[0].spec.platform.aws.rootVolume.encryptionKey}')
          if [[ "$key_arn" != "$KMS_KEY_ARN" ]]; then
              error "KMS key ARN in nodepool spec ('$key_arn') does not match expected ARN ('$KMS_KEY_ARN')."
              return 1
          fi
          log "KMS key ARN is set correctly in nodepool spec: $key_arn"
      else
          error "KMS key ARN file not found at '$kms_key_arn_file'."
          return 1
      fi
  else
      log "KMS disk encryption not enabled. Skipping check."
  fi
  log "✅ KMS encryption config check passed."
  return 0
}

### Main ###
log "Starting Hypershift health checks..."

# Initial setup
export KUBECONFIG=${SHARED_DIR}/kubeconfig
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Handle ROSA/OSD HCP clusters specifically
if [ -f "${SHARED_DIR}/cluster-type" ] ; then
    CLUSTER_TYPE=$(cat "${SHARED_DIR}/cluster-type")
    if [[ "$CLUSTER_TYPE" == "osd" ]] || [[ "$CLUSTER_TYPE" == "rosa" ]]; then
        log "Detected ROSA/OSD HyperShift cluster. Running health checks..."
        print_clusterversion
        check_node_status || exit 1
        retry check_cluster_operators || exit 1
        retry check_pod_status || exit 1
        log "✅ ROSA/OSD health checks passed."
        exit 0
    fi
fi

# Standard HyperShift cluster checks (management and guest)
log "Checking management cluster's HyperShift components..."
if [ -s "${SHARED_DIR}/mgmt_kubeconfig" ] ; then
  export KUBECONFIG=${SHARED_DIR}/mgmt_kubeconfig
  # Print clusterversion only if the management cluster is an OpenShift cluster
  if oc get ns openshift &>/dev/null; then
      print_clusterversion
  fi

  check_kms_encryption_config || exit 1
  retry check_control_plane_pod_status || exit 1
else
    warn "Management kubeconfig not found or empty. Skipping management cluster checks."
fi

log "Checking guest cluster..."
export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
check_disabled_capability || exit 1
print_clusterversion
check_node_status || exit 1
retry check_cluster_operators || exit 1
retry check_pod_status || exit 1

log "Saving guest cluster pod list to artifacts..."
oc get pod -A > "${ARTIFACT_DIR}/guest-pods"

log "✅ All health checks passed."
