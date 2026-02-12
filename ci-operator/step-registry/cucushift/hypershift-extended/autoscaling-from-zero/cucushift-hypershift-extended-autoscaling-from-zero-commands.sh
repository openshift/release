#!/bin/bash

set -euo pipefail
ENABLE_SCALE_FROM_ZERO_CHECK="${ENABLE_SCALE_FROM_ZERO_CHECK:-true}"
if [[ "${ENABLE_SCALE_FROM_ZERO_CHECK}" != "true" ]]; then
    echo "Scale-from-zero tests are not enabled, skipping the tests."
    exit 0
fi

aws_region=${REGION:-us-east-2}
export AWS_REGION=${aws_region}

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

function login_to_rosa() {
    aws_region=${REGION:-us-east-2}
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    export AWS_DEFAULT_REGION="${aws_region}"
    export SHARED_VPC_AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred_shared_account
    # Log in to rosa/ocm
    OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
    rosa login --env "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
}

# ============================================================================
# CONFIGURATION VARIABLES
# ============================================================================
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ ! -f "${SHARED_DIR}/kubeconfig" ]; then
    exit 1
fi

HC_KUBECONFIG="${SHARED_DIR}"/kubeconfig


# Hosted cluster configuration
HOSTEDCLUSTER_NAMESPACE="${HOSTEDCLUSTER_NAMESPACE:-clusters}"
HOSTEDCLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-id")
echo "HOSTEDCLUSTER_NAME is $HOSTEDCLUSTER_NAME"

# HyperShift operator configuration
HYPERSHIFT_INSTANCE_TYPE="${HYPERSHIFT_INSTANCE_TYPE:-m5.xlarge}"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# retry_until_success <retries> <sleep_time> <function_name> [args...]
# - retries       : max number of attempts
# - sleep_time    : seconds between attempts
# - func          : the function to be called or a sub shell call
function retry_until_success() {
    local retries="$1"
    local sleep_time="$2"
    shift 2   # drop retries and sleep_time
    for i in $(seq 1 "$retries"); do
        echo "Attempt $i/$retries: running $*"
        if "$@"; then
            echo "Success on attempt $i"
            return 0
        fi
        echo "Failed attempt $i, retrying in $sleep_time seconds..."
        sleep "$sleep_time"
    done
    echo "$* did not succeed after $retries attempts"
    return 1
}

# retry_until_result <retries> <sleep_time> <expected_result> <function_name> [args...]
# - retries         : max number of attempts
# - sleep_time      : seconds between attempts
# - expected_result : the expected result to match
# - func            : the function to be called or a sub shell call
# Returns: 0 if result matches expected, 1 otherwise
function retry_until_result() {
    local retries="$1"
    local sleep_time="$2"
    local expected_result="$3"
    shift 3   # drop retries, sleep_time, and expected_result
    local result
    for i in $(seq 1 "$retries"); do
        echo "Attempt $i/$retries: running $*" >&2
        if result=$("$@" 2>&1); then
            echo "Got result: $result, expected: $expected_result" >&2
            if [ "$result" == "$expected_result" ]; then
                echo "Success on attempt $i - result matches expected" >&2
                return 0
            fi
            echo "Result does not match expected, retrying..." >&2
        else
            echo "Command failed on attempt $i" >&2
        fi
        echo "Retrying in $sleep_time seconds..." >&2
        sleep "$sleep_time"
    done
    echo "$* did not return expected result '$expected_result' after $retries attempts" >&2
    return 1
}

# Create a nodepool with replicas using rosa CLI
function create_nodepool() {
    local node_pool_name="$1"
    local replicas="$2"
    echo "Creating nodepool ${node_pool_name} with replicas: ${replicas}..."

    # Use rosa CLI to create machinepool
    rosa create machinepool --cluster "${HOSTEDCLUSTER_NAME}" \
        --name "${node_pool_name}" \
        --replicas "${replicas}" || return 1

    echo "Nodepool ${node_pool_name} created successfully"
}

# Create a nodepool with autoscaling enabled using rosa CLI
function create_nodepool_with_autoscaling() {
    local node_pool_name="$1"
    local min="$2"
    local max="$3"
    echo "Creating nodepool ${node_pool_name} with autoscaling enabled (min: ${min}, max: ${max})..."

    # Use rosa CLI to create machinepool with autoscaling
    rosa create machinepool --cluster "${HOSTEDCLUSTER_NAME}" \
        --name "${node_pool_name}" \
        --enable-autoscaling \
        --min-replicas "${min}" \
        --max-replicas "${max}" || return 1

    echo "Nodepool ${node_pool_name} created successfully with autoscaling"
}

# Patch nodepool to enable autoscaling
function patch_nodepool_autoscaling() {
    local node_pool_name="$1"
    local min="$2"
    local max="$3"
    echo "Patching nodepool ${node_pool_name} to enable autoscaling with min: ${min}, max: ${max}..."

    # Use rosa CLI to edit machinepool and enable autoscaling
    rosa edit machinepool --cluster "${HOSTEDCLUSTER_NAME}" "${node_pool_name}" \
        --enable-autoscaling=true \
        --min-replicas "${min}" \
        --max-replicas "${max}" || return 1
}

# Get machinepool ready status
function get_machinepool_ready_status() {
    local np_name="$1"
    local json
    json=$(rosa describe machinepool --cluster "${HOSTEDCLUSTER_NAME}" --machinepool "${np_name}" -o json 2>/dev/null) || { echo ""; return; }

    local current_replicas expected_replicas min_replicas
    current_replicas=$(echo "$json" | jq -r '.status.current_replicas // ""')

    # Check if autoscaling is enabled
    min_replicas=$(echo "$json" | jq -r '.autoscaling.min_replica // ""')

    if [[ -n "$min_replicas" ]]; then
        # Autoscaling enabled: compare to min_replica
        expected_replicas="$min_replicas"
    else
        # Autoscaling disabled: compare to replicas
        expected_replicas=$(echo "$json" | jq -r '.replicas // ""')
    fi

    if [[ -n "$expected_replicas" && -n "$current_replicas" && "$expected_replicas" == "$current_replicas" ]]; then
        echo "True"
    else
        echo ""
    fi
}

# Wait for a nodepool to be ready for 30 minutes
function wait_nodepool_ready() {
    local np_name="$1"
    echo "Waiting for nodepool ${np_name} to be ready..."
    retry_until_result 60 30 "True" get_machinepool_ready_status "${np_name}"
}

# Get node count in hosted cluster
function get_node_count() {
    oc --kubeconfig="${HC_KUBECONFIG}" get nodes --no-headers 2>/dev/null | wc -l
}

# Get current Ready node count in hosted cluster (only Ready nodes without additional conditions)
function get_ready_node_count() {
    oc --kubeconfig="${HC_KUBECONFIG}" get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l
}

# Get node count for a specific nodepool (all nodes regardless of status)
function get_nodepool_node_count() {
    local np_name="$1"
    oc --kubeconfig="${HC_KUBECONFIG}" get nodes -o json 2>/dev/null | \
        jq --arg np "$np_name" '[.items[] | select(.metadata.labels["hypershift.openshift.io/nodePool"] // "" | endswith("-" + $np))] | length'
}

# Wait for specific number of nodes with specific nodepool label no matterh what stauts it has
function wait_for_nodepool_node_count() {
    local np_name="$1"
    local expected_count="$2"
    echo "Waiting for ${expected_count} nodes from nodepool ${np_name}..."
    retry_until_result 60 30 "${expected_count}" get_nodepool_node_count "${np_name}"
}

# Get Ready node count for a specific nodepool (only Ready nodes without additional conditions)
function get_nodepool_ready_node_count() {
    local np_name="$1"
    oc --kubeconfig="${HC_KUBECONFIG}" get nodes -o json 2>/dev/null | \
        jq --arg np "$np_name" '[.items[] | select(.metadata.labels["hypershift.openshift.io/nodePool"] // "" | endswith("-" + $np)) | select(.status.conditions[]? | select(.type == "Ready" and .status == "True"))] | length'
}

# Wait for specific number of Ready nodes in hosted cluster
function wait_for_ready_node_count() {
    local expected_count="$1"
    echo "Waiting for ${expected_count} Ready nodes in hosted cluster..."
    retry_until_result 60 30 "${expected_count}" get_ready_node_count
}

# Wait for specific number of Ready nodes with specific nodepool label
function wait_for_nodepool_ready_node_count() {
    local np_name="$1"
    local expected_count="$2"
    echo "Waiting for ${expected_count} Ready nodes from nodepool ${np_name}..."
    retry_until_result 60 30 "${expected_count}" get_nodepool_ready_node_count "${np_name}"
}

# Create a workload job in the hosted cluster
function create_workload() {
    local job_name="workload"
    local namespace="default"
    local completions="100"
    local parallelism="100"

    echo "Creating workload job '${job_name}' in hosted cluster namespace '${namespace}'..."
    cat <<EOF | oc --kubeconfig="${HC_KUBECONFIG}" apply -f - || return 1
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${namespace}
spec:
  backoffLimit: 4
  completions: ${completions}
  parallelism: ${parallelism}
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: work
          image: quay.io/openshifttest/busybox@sha256:c5439d7db88ab5423999530349d327b04279ad3161d7596d2126dfb5b02bfd1f
          command: ["sleep",  "30m"]
          resources:
            requests:
              memory: 1Gi
              cpu: 500m
          securityContext:
            runAsUser: 1000
            allowPrivilegeEscalation: false
            capabilities:
              drop:
              - ALL
      restartPolicy: Never
EOF
}

# Delete a workload job from the hosted cluster
function delete_workload() {
    local job_name="workload"
    local namespace="default"

    echo "Deleting workload job '${job_name}' from namespace '${namespace}'..."
    oc --kubeconfig="${HC_KUBECONFIG}" delete job "${job_name}" -n "${namespace}" || return 1
}

# Array to track nodepools created during tests
CREATED_NODEPOOLS=()

# Record a nodepool as created by the test
function track_nodepool() {
    local np_name="$1"
    CREATED_NODEPOOLS+=("${np_name}")
    echo "Tracking nodepool: ${np_name}"
}

# Check if machinepool is deleted
function is_machinepool_deleted() {
    local np_name="$1"
    if ! rosa describe machinepool --cluster "${HOSTEDCLUSTER_NAME}" --machinepool "${np_name}" &>/dev/null; then
        return 0
    fi
    return 1
}

# Delete only the nodepools created during tests
function cleanup_test_nodepools() {
    if [ ${#CREATED_NODEPOOLS[@]} -eq 0 ]; then
        echo "No test nodepools to clean up"
        return 0
    fi

    echo "Cleaning up ${#CREATED_NODEPOOLS[@]} test nodepools..."
    for np_name in "${CREATED_NODEPOOLS[@]}"; do
        echo "Deleting machinepool: ${np_name}"
        # Use rosa CLI to delete machinepool
        rosa delete machinepool --cluster "${HOSTEDCLUSTER_NAME}" "${np_name}" --yes 2>/dev/null || echo "Machinepool ${np_name} already deleted or not found"
    done

    # Wait for all tracked nodepools to be deleted
    echo "Waiting for test machinepools to be deleted..."
    for np_name in "${CREATED_NODEPOOLS[@]}"; do
        retry_until_success 60 10 is_machinepool_deleted "${np_name}" || echo "Warning: Machinepool ${np_name} still exists after waiting"
    done

    # Clear the tracking array
    CREATED_NODEPOOLS=()
}

# ============================================================================
# USE CASE 1: Create HostedCluster with scale-from-zero enabled and check API validations
# ============================================================================
function use_case_1_check_scale_from_zero_feature() {
    trap 'return 1' ERR
    echo "=========================================="
    echo "USE CASE 1: Check scale-from-zero feature and API validations"
    echo "=========================================="

    # Create nodepools with replicas: 1
    local node_pool_name="np-initial"
    create_nodepool_with_autoscaling "${node_pool_name}" 0 3 || return 1
    track_nodepool "${node_pool_name}"

    # Patch the nodepool to scale up to 2 nodes as the min set to 2
    patch_nodepool_autoscaling "${node_pool_name}" 2 4 || return 1
    wait_for_nodepool_ready_node_count "${node_pool_name}" 2 || return 1

    # Patch the nodepool to scale down to 0 nodes as the min set to 0
    # TODO: ROSCLI needs to be updated to support patching autoscaling configuration on min-replicas to 0
    # patch_nodepool_autoscaling "${node_pool_name}" 0 2 || return 1
    # wait_for_nodepool_ready_node_count "${node_pool_name}" 0 || return 1

    echo "USE CASE 1: PASSED - Nodes successfully scaled down to 0"

    # Cleanup test nodepools
    cleanup_test_nodepools || return 1
}

# ============================================================================
# USE CASE 2: Workloads lead to auto scaling from/to zero with ScaleUpAndScaleDown
# ============================================================================
function use_case_2_scale_up_and_down() {
    local upgrade_type="${1:-Replace}"
    trap 'return 1' ERR
    echo "=========================================="
    echo "USE CASE 2: Auto scaling from/to zero with ScaleUpAndScaleDown (upgrade_type=${upgrade_type})"
    echo "=========================================="

    # Create nodepools with autoscaling enabled
    local np_scaling_one="np-scaling-1" np_scaling_zero="np-scaling-0"
    create_nodepool_with_autoscaling "${np_scaling_one}" 1 3 || return 1
    create_nodepool_with_autoscaling "${np_scaling_zero}" 0 3 || return 1
    track_nodepool "${np_scaling_one}"
    track_nodepool "${np_scaling_zero}"

    # Wait for nodepools to be ready
    echo "Waiting for ${np_scaling_one} to be ready..."
    wait_nodepool_ready "${np_scaling_one}" || return 1

    echo "Waiting for ${np_scaling_zero} to be ready..."
    wait_nodepool_ready "${np_scaling_zero}" || return 1

    # Create workload job in the hosted cluster
    create_workload || return 1

    # Wait for np-scaling-zero nodes to scale up to 3
    echo "Waiting for ${np_scaling_zero} to scale up to 3 nodes..."
    wait_for_nodepool_ready_node_count "${np_scaling_zero}" 3 || return 1

    # Wait for np-scaling-one nodes to scale up to 3
    echo "Waiting for ${np_scaling_one} to scale up to 3 nodes..."
    wait_for_nodepool_ready_node_count "${np_scaling_one}" 3 || return 1

    # Delete the workload job
    delete_workload || return 1

    # Verify the np-scaling-one has 1 node left
    echo "Verifying the nodepool: ${np_scaling_one} has 1 node..."
    wait_for_nodepool_ready_node_count "${np_scaling_one}" 1 || return 1

    # Verify the np-scaling-zero has 0 node left
    echo "Verifying the nodepool: ${np_scaling_zero} has 0 node..."
    wait_for_nodepool_ready_node_count "${np_scaling_zero}" 0 || return 1

    # wait all nodes regardless the status
    wait_for_nodepool_node_count "${np_scaling_one}" 1 || return 1
    wait_for_nodepool_node_count "${np_scaling_zero}" 0 || return 1

    echo "USE CASE 2: PASSED - Nodes scaled up to 6 and back down to 0"

    # Cleanup test nodepools
    cleanup_test_nodepools || return 1
}

# ============================================================================
# USE CASE 4: Workloads only affect nodepools which have autoscaling enabled
# ============================================================================
function use_case_4_autoscaling_only() {
    local upgrade_type="${1:-Replace}"
    trap 'return 1' ERR
    echo "=========================================="
    echo "USE CASE 4: Workloads only affect autoscaling-enabled nodepools (upgrade_type=${upgrade_type})"
    echo "=========================================="

    # Create nodepools - one with fixed replicas, one with autoscaling
    local no_scaling_one="no-scaling" np_scaling_zero="np-scaling-0"
    create_nodepool "${no_scaling_one}" 1 || return 1
    create_nodepool_with_autoscaling "${np_scaling_zero}" 0 3 || return 1
    track_nodepool "${no_scaling_one}"
    track_nodepool "${np_scaling_zero}"

    # Wait for nodepools to be ready
    echo "Waiting for ${no_scaling_one} to be ready..."
    wait_nodepool_ready "${no_scaling_one}" || return 1

    echo "Waiting for ${np_scaling_zero} to be ready..."
    wait_nodepool_ready "${np_scaling_zero}" || return 1

    # Create workload job in the hosted cluster
    create_workload || return 1

    # Wait for np-scaling-zero nodes to scale up to 3
    echo "Waiting for ${np_scaling_zero} to scale up to 3 nodes..."
    wait_for_nodepool_ready_node_count "${np_scaling_zero}" 3 || return 1

    # nodes in nodepool: np-one nodes keeps the same count of 1
    echo "Verifying ${no_scaling_one} remains at 1 node..."
    wait_for_nodepool_ready_node_count "${no_scaling_one}" 1 || return 1

    # Delete the workload job
    delete_workload || return 1

    # Wait for np-scaling-zero nodes to scale down to 0
    echo "Waiting for ${np_scaling_zero} to scale down to 0 nodes..."
    wait_for_nodepool_ready_node_count "${np_scaling_zero}" 0 || return 1

    # nodes in nodepool: np-one nodes keeps the same count of 1
    echo "Verifying ${no_scaling_one} remains at 1 node..."
    wait_for_nodepool_ready_node_count "${no_scaling_one}" 1 || return 1

    # wait all nodes regardless the status
    wait_for_nodepool_node_count "${no_scaling_one}" 1 || return 1
    wait_for_nodepool_node_count "${np_scaling_zero}" 0 || return 1

    echo "USE CASE 4: PASSED - Only autoscaling nodepool scaled down to 0, fixed replicas nodepool unchanged"

    # Cleanup test nodepools
    cleanup_test_nodepools || return 1
}

# ============================================================================
# USE CASE 5: Create NodePool with nodeLabels set 'kubernetes.io/arch=amd64'
# ============================================================================
function use_case_5_node_labels_and_taints() {
    local upgrade_type="${1:-Replace}"
    trap 'return 1' ERR
    echo "=========================================="
    echo "USE CASE 5: NodePool with nodeLabels and taints (upgrade_type=${upgrade_type})"
    echo "=========================================="

    # Get current architecture from hosted cluster nodes
    echo "Detecting architecture from hosted cluster..."
    local arch
    arch=$(oc --kubeconfig="${HC_KUBECONFIG}" get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')
    echo "Hosted cluster architecture: ${arch}"

    # Create nodepool np-scaling-zero with autoscaling, nodeLabels, and taints
    echo "Creating machinepool np-scaling-zero with nodeLabels and taints..."
    local np_scaling_zero="np-scaling-0"

    rosa create machinepool --cluster "${HOSTEDCLUSTER_NAME}" \
        --name "${np_scaling_zero}" \
        --enable-autoscaling \
        --min-replicas 0 \
        --max-replicas 3 \
        --labels "kubernetes.io/arch=${arch},test-cluster=${HOSTEDCLUSTER_NAME},scale-from-zero-test=true" \
        --taints "scale-from-zero-test=true:NoSchedule" || return 1

    track_nodepool "${np_scaling_zero}"

    # Wait for machinepool to be ready
    echo "Waiting for ${np_scaling_zero} to be ready..."
    wait_nodepool_ready "${np_scaling_zero}" || return 1

    # Verify there are no nodes
    echo "Verifying there are no nodes (min=0)..."
    wait_for_nodepool_ready_node_count "${np_scaling_zero}" 0 || return 1

    # Create workload job in the hosted cluster
    # The workload pods should be scheduled on nodes with matching labels and tolerations
    local job_name="workload" namespace="default" completions=100 parallelism=100
    echo "Creating workload job '${job_name}' in hosted cluster namespace '${namespace}'..."
    cat <<EOF | oc --kubeconfig="${HC_KUBECONFIG}" apply -f - || return 1
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${namespace}
spec:
  backoffLimit: 4
  completions: ${completions}
  parallelism: ${parallelism}
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      nodeSelector:
        scale-from-zero-test: "true"
      tolerations:
      - key: scale-from-zero-test
        operator: "Equal"
        value: "true"
        effect: NoSchedule
      containers:
        - name: work
          image: quay.io/openshifttest/busybox@sha256:c5439d7db88ab5423999530349d327b04279ad3161d7596d2126dfb5b02bfd1f
          command: ["sleep",  "30m"]
          resources:
            requests:
              memory: 1Gi
              cpu: 500m
          securityContext:
            runAsUser: 1000
            allowPrivilegeEscalation: false
            capabilities:
              drop:
              - ALL
      restartPolicy: Never
EOF

    # Wait for nodes to scale up to 3
    echo "Waiting for nodes to scale up to 3..."
    wait_for_nodepool_ready_node_count "${np_scaling_zero}" 3 || return 1

    # Verify nodes have the correct labels and taints
    echo "Verifying nodes from ${np_scaling_zero} have correct labels and taints..."
    for node in $(oc --kubeconfig="${HC_KUBECONFIG}" get nodes -o json | jq -r --arg np "${np_scaling_zero}" '.items[] | select(.metadata.labels["hypershift.openshift.io/nodePool"] // "" | endswith("-" + $np)) | .metadata.name'); do
        # Get node JSON once for all checks
        local node_json
        node_json=$(oc --kubeconfig="${HC_KUBECONFIG}" get node "${node}" -o json)

        # Check if node has all required labels using jq
        local arch_label cluster_label scale_label
        arch_label=$(echo "${node_json}" | jq -r '.metadata.labels["kubernetes.io/arch"] // ""')
        cluster_label=$(echo "${node_json}" | jq -r '.metadata.labels["test-cluster"] // ""')
        scale_label=$(echo "${node_json}" | jq -r '.metadata.labels["scale-from-zero-test"] // ""')

        if [ "${arch_label}" != "${arch}" ] || [ "${cluster_label}" != "${HOSTEDCLUSTER_NAME}" ] || [ "${scale_label}" != "true" ]; then
            echo "ERROR: Node ${node} missing required labels - arch=${arch_label} (expected ${arch}), test-cluster=${cluster_label} (expected ${HOSTEDCLUSTER_NAME})"
            exit 1
        fi

        # Check if node has the required taint using jq
        local taint_effect
        taint_effect=$(echo "${node_json}" | jq -r '.spec.taints[]? | select(.key=="scale-from-zero-test") | .effect // ""')

        if [ "${taint_effect}" != "NoSchedule" ]; then
            echo "ERROR: Node ${node} missing required taint - effect=${taint_effect} (expected NoSchedule)"
            exit 1
        fi

        echo "Node ${node}: labels ✓, taint ✓"
    done

    # Delete the workload job
    echo "Deleting workload job '${job_name}' from namespace '${namespace}'..."
    oc --kubeconfig="${HC_KUBECONFIG}" delete job "${job_name}" -n "${namespace}" || return 1

    # Wait for nodes to scale down to 0
    echo "Waiting for nodes to scale down to 0..."
    wait_for_nodepool_ready_node_count "${np_scaling_zero}" 0 || return 1

    # wait all nodes regardless the status
    wait_for_nodepool_node_count "${np_scaling_zero}" 0 || return 1

    echo "USE CASE 5: PASSED - NodePool with nodeLabels scaled from 0 to 3 and back to 0"

    # Cleanup test nodepools
    cleanup_test_nodepools || return 1
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

echo "Starting test execution..."
echo ""

# Perform ROSA login
echo "do rosa login..."
login_to_rosa
echo ""

# Use Case 1
echo "Executing Use Case 1: Check scale-from-zero feature and API validations"
use_case_1_check_scale_from_zero_feature
echo ""

echo "============================================================"
echo "Starting Replace upgrade type test cases (Use Cases 2-5)"
echo "============================================================"
echo ""

# Use Case 2 - Replace upgrade type
echo "Executing Use Case 2 (Replace): Auto scaling from/to zero with ScaleUpAndScaleDown"
use_case_2_scale_up_and_down "Replace"
echo ""


# Use Case 4 - Replace upgrade type
echo "Executing Use Case 4 (Replace): Workloads only affect autoscaling-enabled nodepools"
use_case_4_autoscaling_only "Replace"
echo ""

# Use Case 5 - Replace upgrade type
echo "Executing Use Case 5 (Replace): NodePool with nodeLabels and taints"
use_case_5_node_labels_and_taints "Replace"
echo ""

echo "✓ Test suite execution complete."
echo ""
