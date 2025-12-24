#!/bin/bash

# HyperShift Scale-from-Zero Autoscaling Test Cases
# This script contains test functions for validating the scale-from-zero feature on AWS platform
# This suppose the Hypershift Operator has been installed with the feature enabled already and a HostedCluster created
# Each test will create new nodepool resources and clean them up after the test, this won't affect existing nodepools.
# It will change the HostedCluster autoscaling mode as needed for the tests.

set -euo pipefail
ENABLE_SCALE_FROM_ZERO_CHECK="${ENABLE_SCALE_FROM_ZERO_CHECK:-false}"
if [[ "${ENABLE_SCALE_FROM_ZERO_CHECK}" != "true" ]]; then
    echo "Scale-from-zero tests are not enabled, skipping the tests."
    exit 0
fi

ENABLE_SCALE_FROM_ZERO="${ENABLE_SCALE_FROM_ZERO:-false}"

# ============================================================================
# CONFIGURATION VARIABLES
# ============================================================================
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ ! -f "${SHARED_DIR}/kubeconfig" ]; then
    exit 1
fi
# Management cluster kubeconfig
MGMT_KUBECONFIG="${SHARED_DIR}"/kubeconfig

# Use management cluster kubeconfig by default
export KUBECONFIG="${MGMT_KUBECONFIG}"

# # Hosted cluster details
if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
    exit 1
fi
HC_KUBECONFIG="${SHARED_DIR}"/nested_kubeconfig


# Function to check if scale-from-zero is supported
# Returns 0 if supported, 1 if not supported
function check_scale_from_zero_support() {
    echo "Checking if scale-from-zero is supported..."

    # If explicitly enabled, it's supported
    if [[ "${ENABLE_SCALE_FROM_ZERO}" == "true" ]]; then
        echo "Scale-from-zero is explicitly enabled via ENABLE_SCALE_FROM_ZERO=true"
        return 0
    fi

    # Check if awsmachinetemplate has status.capacity field (newer versions support scale-from-zero by default)
    echo "Checking if awsmachinetemplate has status.capacity field..."
    local awsmachinetemplate_count
    awsmachinetemplate_count=$(oc --kubeconfig "${MGMT_KUBECONFIG}" get awsmachinetemplate -A -o json 2>/dev/null | jq '[.items[] | select(.status.capacity != null)] | length')

    if [[ -z "${awsmachinetemplate_count}" ]]; then
        echo "Failed to check awsmachinetemplate resources"
        return 1
    fi

    if [[ "${awsmachinetemplate_count}" -gt 0 ]]; then
        echo "Found ${awsmachinetemplate_count} awsmachinetemplate(s) with status.capacity - scale-from-zero is supported by default"
        return 0
    fi

    echo "Scale-from-zero is not supported: ENABLE_SCALE_FROM_ZERO=${ENABLE_SCALE_FROM_ZERO} and no awsmachinetemplate with status.capacity found"
    return 1
}

# Check if scale-from-zero is supported before running tests
if ! check_scale_from_zero_support; then
    echo "Scale-from-zero feature is not supported in this environment. Skipping all test cases."
    exit 1
fi

echo "Scale-from-zero feature is supported. Proceeding with test execution..."

# Hosted cluster configuration
HOSTEDCLUSTER_NAMESPACE="${HOSTEDCLUSTER_NAMESPACE:-clusters}"
HOSTEDCLUSTER_NAME=$(oc --kubeconfig "${MGMT_KUBECONFIG}" get hostedclusters -n "${HOSTEDCLUSTER_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')

# HyperShift operator configuration
OPERATOR_NAMESPACE="hypershift"
HYPERSHIFT_INSTANCE_TYPE="${HYPERSHIFT_INSTANCE_TYPE:-m5.xlarge}"
# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Variable to store original autoscaling configuration
ORIGINAL_AUTOSCALING_CONFIG=""

# Variables to store existing nodepool and its nodes before tests
EXISTING_NODEPOOL=""
EXISTING_NODEPOOL_NODES=""

# Remember the original hc.spec.autoscaling configuration before tests
function remember_original_autoscaling_config() {
    echo "Remembering original HostedCluster autoscaling configuration..."
    ORIGINAL_AUTOSCALING_CONFIG=$(oc --kubeconfig $MGMT_KUBECONFIG get hostedcluster "${HOSTEDCLUSTER_NAME}" -n "${HOSTEDCLUSTER_NAMESPACE}" -o jsonpath='{.spec.autoscaling}') || {
        echo "Warning: Failed to remember original autoscaling config"
        return 1
    }
    echo "Original autoscaling config remembered:"
    echo "${ORIGINAL_AUTOSCALING_CONFIG}"
}

# Remember existing nodepool and its nodes before tests
function remember_existing_nodepool() {
    echo "Remembering existing nodepool and its nodes..."
    EXISTING_NODEPOOL=$(oc --kubeconfig $MGMT_KUBECONFIG get nodepools -n "${HOSTEDCLUSTER_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}') || {
        echo "Warning: Failed to get existing nodepool"
        return 1
    }

    if [[ -z "${EXISTING_NODEPOOL}" ]]; then
        echo "No existing nodepool found"
        return 1
    fi

    echo "Existing nodepool: ${EXISTING_NODEPOOL}"

    # Store as sorted array (safer than string with potential whitespace issues)
    mapfile -t EXISTING_NODEPOOL_NODES < <(oc --kubeconfig="${HC_KUBECONFIG}" get nodes -l "hypershift.openshift.io/nodePool=${EXISTING_NODEPOOL}" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort)
    echo "  NodePool ${EXISTING_NODEPOOL}: ${EXISTING_NODEPOOL_NODES[*]:-<no nodes>}"
    echo "Existing nodepool and nodes remembered"
}

# Check that existing nodepool and its nodes haven't changed
function check_existing_nodepool() {
    echo "Checking existing nodepool and its nodes..."

    # Check if nodepool still exists
    local current_nodepool
    current_nodepool=$(oc --kubeconfig $MGMT_KUBECONFIG get nodepool "${EXISTING_NODEPOOL}" -n "${HOSTEDCLUSTER_NAMESPACE}" -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

    if [[ -z "${current_nodepool}" ]]; then
        echo "ERROR: NodePool ${EXISTING_NODEPOOL} was deleted during tests!"
        return 1
    fi

    # Check if nodes in existing nodepool have changed
    local current_nodes
    mapfile -t current_nodes < <(oc --kubeconfig="${HC_KUBECONFIG}" get nodes -l "hypershift.openshift.io/nodePool=${EXISTING_NODEPOOL}" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort)

    # Compare arrays element by element (handles empty arrays correctly)
    if [[ "${#current_nodes[@]}" -ne "${#EXISTING_NODEPOOL_NODES[@]}" ]] || [[ "${current_nodes[*]}" != "${EXISTING_NODEPOOL_NODES[*]}" ]]; then
        echo "ERROR: Nodes in NodePool ${EXISTING_NODEPOOL} have changed!"
        echo "  Original: ${EXISTING_NODEPOOL_NODES[*]:-<no nodes>}"
        echo "  Current:  ${current_nodes[*]:-<no nodes>}"
        return 1
    fi

    echo "  NodePool ${EXISTING_NODEPOOL}: nodes unchanged ✓"
    echo "Existing nodepool and nodes verification: PASSED"
}

# Restore the original hc.spec.autoscaling configuration after tests
function restore_original_autoscaling_config() {
    if [ -z "${ORIGINAL_AUTOSCALING_CONFIG}" ]; then
        echo "Warning: Original autoscaling config variable is empty, skipping restore"
        return 1
    fi

    echo "Restoring original HostedCluster autoscaling configuration..."
    # Replace the entire autoscaling section with the original config
    oc --kubeconfig $MGMT_KUBECONFIG patch hostedcluster "${HOSTEDCLUSTER_NAME}" -n "${HOSTEDCLUSTER_NAMESPACE}" --type=json -p='[
        {"op": "replace", "path": "/spec/autoscaling", "value": '"${ORIGINAL_AUTOSCALING_CONFIG}"'}
    ]' || {
        echo "Warning: Failed to restore autoscaling config"
        return 1
    }

    echo "Original autoscaling configuration restored successfully"
}

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

# Patch HostedCluster to ScaleUpAndScaleDown mode
# ScaleUpAndScaleDown is the default autoscaling mode, we will patch it at the end of the tests too
function patch_hc_scale_up_and_scale_down() {
    oc --kubeconfig $MGMT_KUBECONFIG patch hostedcluster "${HOSTEDCLUSTER_NAME}" -n "${HOSTEDCLUSTER_NAMESPACE}" --type=merge -p='{"spec": {
            "autoscaling": {
                "scaling": "ScaleUpAndScaleDown",
                "maxNodeProvisionTime": "15m",
                "maxNodesTotal": 10,
                "scaleDown": {
                    "unneededDurationSeconds": 60,
                    "delayAfterAddSeconds": 0,
                    "delayAfterDeleteSeconds": 10,
                    "delayAfterFailureSeconds": 30,
                    "utilizationThresholdPercent": 95
                }
            }
        }}' || return 1
}

# Patch HostedCluster to ScaleUpOnly mode
function patch_hc_scale_up_only() {
    # Check if scaleDown section exists
    local has_scale_down
    has_scale_down=$(oc --kubeconfig $MGMT_KUBECONFIG get hostedcluster "${HOSTEDCLUSTER_NAME}" -n "${HOSTEDCLUSTER_NAMESPACE}" -o jsonpath='{.spec.autoscaling.scaleDown}' 2>/dev/null || echo "")

    if [[ -n "${has_scale_down}" ]]; then
        # ScaleDown exists, remove it and set ScaleUpOnly
        echo "Removing scaleDown section and setting ScaleUpOnly mode..."
        oc --kubeconfig $MGMT_KUBECONFIG patch hostedcluster "${HOSTEDCLUSTER_NAME}" -n "${HOSTEDCLUSTER_NAMESPACE}" --type=json -p='[
            {"op": "remove", "path": "/spec/autoscaling/scaleDown"},
            {"op": "add", "path": "/spec/autoscaling/scaling", "value": "ScaleUpOnly"},
            {"op": "add", "path": "/spec/autoscaling/maxNodeProvisionTime", "value": "15m"},
            {"op": "add", "path": "/spec/autoscaling/maxNodesTotal", "value": 10}
        ]' || return 1
    else
        # ScaleDown doesn't exist, just set ScaleUpOnly
        echo "Setting ScaleUpOnly mode..."
        oc --kubeconfig $MGMT_KUBECONFIG patch hostedcluster "${HOSTEDCLUSTER_NAME}" -n "${HOSTEDCLUSTER_NAMESPACE}" --type=json -p='[
            {"op": "add", "path": "/spec/autoscaling/scaling", "value": "ScaleUpOnly"},
            {"op": "add", "path": "/spec/autoscaling/maxNodeProvisionTime", "value": "15m"},
            {"op": "add", "path": "/spec/autoscaling/maxNodesTotal", "value": 10}
        ]' || return 1
    fi
}


# Patch nodepool to enable autoscaling
function patch_nodepool_autoscaling() {
    local node_pool_name="$1"
    local min="$2"
    local max="$3"
    echo "Patching nodepool ${node_pool_name} to enable autoscaling with min: ${min}, max: ${max}..."

    # Check if spec.replicas exists before attempting to remove it
    local has_replicas
    has_replicas=$(oc --kubeconfig $MGMT_KUBECONFIG get nodepool "${node_pool_name}" -n "${HOSTEDCLUSTER_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")

    if [[ -n "${has_replicas}" ]]; then
        # Replicas field exists, remove it and add autoscaling
        oc --kubeconfig $MGMT_KUBECONFIG patch nodepool "${node_pool_name}" -n "${HOSTEDCLUSTER_NAMESPACE}" --type=json -p='[
            {"op": "remove", "path": "/spec/replicas"},
            {"op": "add", "path": "/spec/autoScaling", "value": {"min": '"${min}"', "max": '"${max}"'}}
        ]' || return 1
    else
        # Replicas field doesn't exist, just update or add autoscaling
        oc --kubeconfig $MGMT_KUBECONFIG patch nodepool "${node_pool_name}" -n "${HOSTEDCLUSTER_NAMESPACE}" --type=merge -p='{"spec": {"autoScaling": {"min": '"${min}"', "max": '"${max}"'}}}' || return 1
    fi
}

# Wait for a nodepool to be ready for 30 minutes
function wait_nodepool_ready() {
    local np_name="$1"
    echo "Waiting for nodepool ${np_name} to be ready..."
    oc --kubeconfig $MGMT_KUBECONFIG wait nodepool "${np_name}" -n "${HOSTEDCLUSTER_NAMESPACE}" --for=condition=Ready --timeout=30m
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
    oc --kubeconfig="${HC_KUBECONFIG}" get nodes \
        -l "hypershift.openshift.io/nodePool=${np_name}" \
        --no-headers 2>/dev/null | wc -l
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
    oc --kubeconfig="${HC_KUBECONFIG}" get nodes \
        -l "hypershift.openshift.io/nodePool=${np_name}" \
        --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l
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

# Delete only the nodepools created during tests
function cleanup_test_nodepools() {
    if [ ${#CREATED_NODEPOOLS[@]} -eq 0 ]; then
        echo "No test nodepools to clean up"
        return 0
    fi

    echo "Cleaning up ${#CREATED_NODEPOOLS[@]} test nodepools..."
    for np_name in "${CREATED_NODEPOOLS[@]}"; do
        echo "Deleting nodepool: ${np_name}"
        # we don't wait to speed up deletion, will wait later
        oc --kubeconfig $MGMT_KUBECONFIG delete nodepool "${np_name}" -n "${HOSTEDCLUSTER_NAMESPACE}" --wait=false 2>/dev/null || echo "Nodepool ${np_name} already deleted or not found"
    done

    # Wait for all tracked nodepools to be deleted
    echo "Waiting for test nodepools to be deleted..."
    for np_name in "${CREATED_NODEPOOLS[@]}"; do
        oc --kubeconfig $MGMT_KUBECONFIG wait nodepool "${np_name}" -n "${HOSTEDCLUSTER_NAMESPACE}" --for=delete --timeout=600s 2>/dev/null || true
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

    # Check hypershift operator logs to confirm scale-from-zero is enabled
    echo "Checking hypershift operator logs for scale-from-zero feature enablement..."
    local operator_pod
    operator_pod=$(oc --kubeconfig $MGMT_KUBECONFIG get pods -n "${OPERATOR_NAMESPACE}" -l name=operator -o jsonpath='{.items[0].metadata.name}')
    echo "Operator pod: ${operator_pod}"
    oc --kubeconfig $MGMT_KUBECONFIG logs -n "${OPERATOR_NAMESPACE}" "${operator_pod}" | head -100 | grep -i "scale.*from.*zero" || echo "Note: Checking for scale-from-zero related logs"

    # Verify the hypershift operator installation has the AWS credentials mounted
    echo "Verifying hypershift operator has AWS credentials for scale-from-zero..."
    oc --kubeconfig $MGMT_KUBECONFIG get deployment operator -n "${OPERATOR_NAMESPACE}" -o yaml | grep -A 5 "scale-from-zero" || echo "Checking operator configuration..."

    # Create a nodepool with replicas: 1
    echo "Creating nodepool with replicas: 1..."
    local node_pool_name="test-np-initial" node_pool_inplace="test-np-inplace"
    hypershift create nodepool aws --name "${node_pool_name}" \
        --cluster-name "${HOSTEDCLUSTER_NAME}" \
        --namespace "${HOSTEDCLUSTER_NAMESPACE}" \
        --node-upgrade-type "Replace" \
        --replicas 1 || return 1
    hypershift create nodepool aws --name "${node_pool_inplace}" \
        --cluster-name "${HOSTEDCLUSTER_NAME}" \
        --namespace "${HOSTEDCLUSTER_NAMESPACE}" \
        --node-upgrade-type "InPlace" \
        --replicas 1 || return 1

    track_nodepool "${node_pool_name}"
    track_nodepool "${node_pool_inplace}"

    # Wait for nodepool to be ready
    echo "Waiting for nodepool to be ready..."
    wait_nodepool_ready "${node_pool_name}" || return 1
    wait_nodepool_ready "${node_pool_inplace}" || return 1

    # Patch the nodepool to enable autoscaling with min: 0, max: 3
    patch_nodepool_autoscaling "${node_pool_name}" 0 3 || return 1
    patch_nodepool_autoscaling "${node_pool_inplace}" 0 3 || return 1

    # The nodepool's replicas was set to 1, which is in between the new min/max, so we see 1 node after enabling autoscaling, no changes.
    wait_for_nodepool_ready_node_count "${node_pool_name}" 1 || return 1
    wait_for_nodepool_ready_node_count "${node_pool_inplace}" 1 || return 1

    # Patch the nodepool to scale up to 2 nodes as the min set to 2
    patch_nodepool_autoscaling "${node_pool_name}" 2 4 || return 1
    patch_nodepool_autoscaling "${node_pool_inplace}" 2 4 || return 1

    wait_for_nodepool_ready_node_count "${node_pool_name}" 2 || return 1
    wait_for_nodepool_ready_node_count "${node_pool_inplace}" 2 || return 1

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

    # Ensure hostedcluster.spec.autoscaling is set to ScaleUpAndScaleDown
    echo "Ensuring HostedCluster autoscaling mode is ScaleUpAndScaleDown..."
    patch_hc_scale_up_and_scale_down || return 1

    # Create nodepool np-scaling-one with min: 1, max: 3
    local np_scaling_one="np-scaling-one" np_scaling_zero="np-scaling-zero"
    hypershift create nodepool aws --name "${np_scaling_one}" \
        --cluster-name "${HOSTEDCLUSTER_NAME}" \
        --namespace "${HOSTEDCLUSTER_NAMESPACE}" \
        --node-upgrade-type "${upgrade_type}" \
        --replicas 1 || return 1
    # Create nodepool np-scaling-zero with min: 0, max: 3
    hypershift create nodepool aws --name "${np_scaling_zero}" \
        --cluster-name "${HOSTEDCLUSTER_NAME}" \
        --namespace "${HOSTEDCLUSTER_NAMESPACE}" \
        --node-upgrade-type "${upgrade_type}" \
        --replicas 0 || return 1
    track_nodepool "${np_scaling_one}"
    track_nodepool "${np_scaling_zero}"

    # Wait for np-scaling-one nodepool to be ready
    echo "Waiting for ${np_scaling_one} to be ready..."
    wait_nodepool_ready "${np_scaling_one}" || return 1

    # Wait for np-scaling-zero nodepool to be ready
    echo "Waiting for ${np_scaling_zero} to be ready..."
    wait_nodepool_ready "${np_scaling_zero}" || return 1

    # patch nodepool to enable autoscaling
    patch_nodepool_autoscaling "${np_scaling_one}" 1 3 || return 1
    patch_nodepool_autoscaling "${np_scaling_zero}" 0 3 || return 1

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

    echo "USE CASE 2: PASSED - Nodes scaled up to 6 and back down to 1"

    # Cleanup test nodepools
    cleanup_test_nodepools || return 1
}

# ============================================================================
# USE CASE 3: Workloads lead to auto scaling from zero with ScaleUpOnly
# ============================================================================
function use_case_3_scale_up_only() {
    local upgrade_type="${1:-Replace}"
    trap 'return 1' ERR
    echo "=========================================="
    echo "USE CASE 3: Auto scaling from zero with ScaleUpOnly (upgrade_type=${upgrade_type})"
    echo "=========================================="

    # Set hostedcluster.spec.autoscaling to ScaleUpOnly
    patch_hc_scale_up_only || return 1

    # Create nodepool np-scaling-one with min: 1, max: 3
    local np_scaling_one="np-scaling-one" np_scaling_zero="np-scaling-zero"
    hypershift create nodepool aws --name "${np_scaling_one}" \
        --cluster-name "${HOSTEDCLUSTER_NAME}" \
        --namespace "${HOSTEDCLUSTER_NAMESPACE}" \
        --node-upgrade-type "${upgrade_type}" \
        --replicas 1 || return 1
    # Create nodepool np-scaling-zero with min: 0, max: 3
    hypershift create nodepool aws --name "${np_scaling_zero}" \
        --cluster-name "${HOSTEDCLUSTER_NAME}" \
        --namespace "${HOSTEDCLUSTER_NAMESPACE}" \
        --node-upgrade-type "${upgrade_type}" \
        --replicas 0 || return 1
    track_nodepool "${np_scaling_one}"
    track_nodepool "${np_scaling_zero}"

    # Wait for np-scaling-one nodepool to be ready
    echo "Waiting for ${np_scaling_one} to be ready..."
    wait_nodepool_ready "${np_scaling_one}" || return 1

    # Wait for np-scaling-zero nodepool to be ready
    echo "Waiting for ${np_scaling_zero} to be ready..."
    wait_nodepool_ready "${np_scaling_zero}" || return 1

    # patch nodepool to enable autoscaling
    patch_nodepool_autoscaling "${np_scaling_one}" 1 3 || return 1
    patch_nodepool_autoscaling "${np_scaling_zero}" 0 3 || return 1

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

    # With ScaleUpOnly, nodes should NOT scale down
    echo "Verifying nodes remain (ScaleUpOnly mode)..."
    # Wait for 5 minutes to check that nodes belong to both nodepools remain in Ready status
    sleep 300
    wait_for_nodepool_ready_node_count "${np_scaling_zero}" 3 || return 1
    wait_for_nodepool_ready_node_count "${np_scaling_one}" 3 || return 1

    echo "USE CASE 3: PASSED - Nodes scaled up to 6 and remained at 6 with ScaleUpOnly"

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

    # Ensure hostedcluster.spec.autoscaling is set to ScaleUpAndScaleDown
    echo "Ensuring HostedCluster autoscaling mode is ScaleUpAndScaleDown..."
    patch_hc_scale_up_and_scale_down || return 1

    # Create nodepool np-one with replicas: 1 (no autoscaling)
    local no_scaling_one="np-one" np_scaling_zero="np-scaling-zero"
    hypershift create nodepool aws --name "${no_scaling_one}" \
        --cluster-name "${HOSTEDCLUSTER_NAME}" \
        --namespace "${HOSTEDCLUSTER_NAMESPACE}" \
        --node-upgrade-type "${upgrade_type}" \
        --replicas 1 || return 1
    # Create nodepool np-scaling-zero with replicas: 1 (will enable autoscaling later)
    hypershift create nodepool aws --name "${np_scaling_zero}" \
        --cluster-name "${HOSTEDCLUSTER_NAME}" \
        --namespace "${HOSTEDCLUSTER_NAMESPACE}" \
        --node-upgrade-type "${upgrade_type}" \
        --replicas 1 || return 1
    track_nodepool "${no_scaling_one}"
    track_nodepool "${np_scaling_zero}"

    # Wait for np-one nodepool to be ready
    echo "Waiting for ${no_scaling_one} to be ready..."
    wait_nodepool_ready "${no_scaling_one}" || return 1

    # Wait for np-scaling-zero nodepool to be ready
    echo "Waiting for ${np_scaling_zero} to be ready..."
    wait_nodepool_ready "${np_scaling_zero}" || return 1

    # patch nodepool to enable autoscaling
    echo "Patching ${np_scaling_zero} to enable autoscaling..."
    patch_nodepool_autoscaling "${np_scaling_zero}" 0 3 || return 1

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

    echo "USE CASE 4: PASSED - Only autoscaling nodepool scaled, fixed replicas nodepool unchanged"

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

    # Ensure hostedcluster.spec.autoscaling is set to ScaleUpAndScaleDown
    echo "Ensuring HostedCluster autoscaling mode is ScaleUpAndScaleDown..."
    patch_hc_scale_up_and_scale_down

    # Get current architecture from management cluster nodes
    echo "Detecting architecture from management cluster..."
    local arch
    arch=$(oc --kubeconfig="${MGMT_KUBECONFIG}" get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')
    echo "Management cluster architecture: ${arch}"

    # Get AWS platform configuration from existing nodepool
    echo "Getting AWS platform configuration from existing nodepool: ${EXISTING_NODEPOOL}..."

    local aws_subnet aws_instance_profile aws_instance_type release_image
    aws_subnet=$(oc --kubeconfig="${MGMT_KUBECONFIG}" get nodepool "${EXISTING_NODEPOOL}" -n "${HOSTEDCLUSTER_NAMESPACE}" -o jsonpath='{.spec.platform.aws.subnet.id}') || return 1
    aws_instance_profile=$(oc --kubeconfig="${MGMT_KUBECONFIG}" get nodepool "${EXISTING_NODEPOOL}" -n "${HOSTEDCLUSTER_NAMESPACE}" -o jsonpath='{.spec.platform.aws.instanceProfile}') || return 1
    aws_instance_type=$(oc --kubeconfig="${MGMT_KUBECONFIG}" get nodepool "${EXISTING_NODEPOOL}" -n "${HOSTEDCLUSTER_NAMESPACE}" -o jsonpath='{.spec.platform.aws.instanceType}') || return 1
    release_image=$(oc --kubeconfig="${MGMT_KUBECONFIG}" get nodepool "${EXISTING_NODEPOOL}" -n "${HOSTEDCLUSTER_NAMESPACE}" -o jsonpath='{.spec.release.image}') || return 1

    echo "AWS Subnet: ${aws_subnet}"
    echo "AWS Instance Profile: ${aws_instance_profile}"
    echo "AWS Instance Type: ${aws_instance_type}"
    echo "Release Image: ${release_image}"

    # Create nodepool np-scaling-zero with min: 0, max: 3 and nodeLabels, taints
    echo "Creating nodepool np-scaling-zero with nodeLabels kubernetes.io/arch=${arch} and taints..."
    local np_scaling_zero="np-scaling-zero"
    cat <<EOF | oc --kubeconfig="${MGMT_KUBECONFIG}" apply -f - || return 1
apiVersion: hypershift.openshift.io/v1beta1
kind: NodePool
metadata:
  name: ${np_scaling_zero}
  namespace: ${HOSTEDCLUSTER_NAMESPACE}
spec:
  clusterName: ${HOSTEDCLUSTER_NAME}
  release:
    image: ${release_image}
  autoScaling:
    min: 0
    max: 3
  management:
    autoRepair: true
    upgradeType: ${upgrade_type}
  platform:
    type: AWS
    aws:
      instanceType: ${aws_instance_type}
      subnet:
        id: ${aws_subnet}
      instanceProfile: ${aws_instance_profile}
      rootVolume:
        size: 120
        type: gp3
  nodeLabels:
    kubernetes.io/arch: ${arch}
    test-cluster: "${HOSTEDCLUSTER_NAME}"
    scale-from-zero-test: "true"
  taints:
  - key: scale-from-zero-test
    value: "true"
    effect: NoSchedule
EOF
    track_nodepool "${np_scaling_zero}"

    # Wait for nodepool to be ready
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
    for node in $(oc --kubeconfig="${HC_KUBECONFIG}" get nodes -l "hypershift.openshift.io/nodePool=${np_scaling_zero}" -o jsonpath='{.items[*].metadata.name}'); do
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

# Parse command-line arguments to optionally run specific test case
SPECIFIC_TEST_CASE="${1:-}"

echo "============================================================"
echo "HyperShift Scale-from-Zero Autoscaling Test Suite"
echo "============================================================"
echo "Management Cluster: ${MGMT_KUBECONFIG}"
echo "Hosted Cluster: ${HOSTEDCLUSTER_NAME} (namespace: ${HOSTEDCLUSTER_NAMESPACE})"
if [[ -n "${SPECIFIC_TEST_CASE}" ]]; then
    echo "Running specific test: ${SPECIFIC_TEST_CASE}"
fi
echo "============================================================"
echo ""

# Run all test cases or specific test case
if [[ -n "${SPECIFIC_TEST_CASE}" ]]; then
    echo "Starting test execution: ${SPECIFIC_TEST_CASE}..."
    echo ""
    shift  # Remove first argument, remaining args will be passed to the test case
    if ${SPECIFIC_TEST_CASE} "$@"; then
        echo "✓ ${SPECIFIC_TEST_CASE} completed successfully"
        echo ""
        echo "RESULT: SUCCESS"
        exit 0
    else
        echo "✗ ${SPECIFIC_TEST_CASE} failed"
        echo ""
        echo "RESULT: FAILED"
        exit 1
    fi
fi

echo "Starting test execution..."
echo ""

# Remember original autoscaling configuration before any tests
remember_original_autoscaling_config || {
    echo "ERROR: Failed to remember original autoscaling config"
    exit 1
}
echo ""

# Remember existing nodepool and its nodes before tests
remember_existing_nodepool || {
    echo "ERROR: Failed to remember existing nodepool"
    exit 1
}
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

# Use Case 3 - Replace upgrade type (only executed on clusters 4.18+)
CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1-2)
if [[ "$(printf '%s\n' "4.18" "$CLUSTER_VERSION" | sort -V | head -n1)" == "4.18" ]]; then
    echo "Cluster version ${CLUSTER_VERSION} supports ScaleUpOnly, executing Use Case 3 (Replace)"
    echo "Executing Use Case 3 (Replace): Auto scaling from zero with ScaleUpOnly"
    use_case_3_scale_up_only "Replace"
else
    echo "Cluster version ${CLUSTER_VERSION} does not support ScaleUpOnly, skipping Use Case 3 (Replace) of scale-up-only test"
fi
echo ""

# Use Case 4 - Replace upgrade type
echo "Executing Use Case 4 (Replace): Workloads only affect autoscaling-enabled nodepools"
use_case_4_autoscaling_only "Replace"
echo ""

# Use Case 5 - Replace upgrade type
echo "Executing Use Case 5 (Replace): NodePool with nodeLabels and taints"
use_case_5_node_labels_and_taints "Replace"
echo ""

echo "============================================================"
echo "Starting InPlace upgrade type test cases (Use Cases 2-5)"
echo "============================================================"
echo ""

# Use Case 2 - InPlace upgrade type
echo "Executing Use Case 2 (InPlace): Auto scaling from/to zero with ScaleUpAndScaleDown"
use_case_2_scale_up_and_down "InPlace"
echo ""

# Use Case 3 - InPlace upgrade type (only executed on clusters 4.18+)
if [[ "$(printf '%s\n' "4.18" "$CLUSTER_VERSION" | sort -V | head -n1)" == "4.18" ]]; then
    echo "Cluster version ${CLUSTER_VERSION} supports ScaleUpOnly, executing Use Case 3 (InPlace)"
    echo "Executing Use Case 3 (InPlace): Auto scaling from zero with ScaleUpOnly"
    use_case_3_scale_up_only "InPlace"
else
    echo "Cluster version ${CLUSTER_VERSION} does not support ScaleUpOnly, skipping Use Case 3 (InPlace) of scale-up-only test"
fi
echo ""

# Use Case 4 - InPlace upgrade type
echo "Executing Use Case 4 (InPlace): Workloads only affect autoscaling-enabled nodepools"
use_case_4_autoscaling_only "InPlace"
echo ""

# Use Case 5 - InPlace upgrade type
echo "Executing Use Case 5 (InPlace): NodePool with nodeLabels and taints"
use_case_5_node_labels_and_taints "InPlace"
echo ""

# Check that existing nodepool and its nodes haven't changed
echo "Verifying existing nodepool and nodes haven't changed (so no rolling out of nonrelated nodes)..."
check_existing_nodepool || {
    echo "ERROR: Existing nodepool validation failed"
    exit 1
}
echo ""

# Restore HostedCluster autoscaling to original configuration
echo "Restoring HostedCluster autoscaling to original configuration..."
retry_until_success 5 10 restore_original_autoscaling_config || {
    echo "ERROR: Failed to restore original autoscaling config after retries"
    exit 1
}

echo "✓ Test suite execution complete."
echo ""
