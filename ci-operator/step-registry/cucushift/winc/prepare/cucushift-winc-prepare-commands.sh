#!/bin/bash

# Enable strict mode and debug output
set -o errexit
set -o nounset
set -o pipefail
set -x

# Constants
WINC_TEST_CM="winc-test-config"
DEFAULT_NAMESPACE="winc-test"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_FILE="/tmp/winc-test-$(date +%Y%m%d-%H%M%S).log"

# Function to print debug message with timestamp and log to file
function debug_msg() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[DEBUG ${timestamp}] $1"
    echo "${message}" | tee -a "${LOG_FILE}"
}

function error_msg() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[ERROR ${timestamp}] $1"
    echo "${message}" | tee -a "${LOG_FILE}"
}

# Function to log command output
function log_cmd_output() {
    local cmd="$1"
    local output
    debug_msg "Executing command: ${cmd}"
    if output=$($cmd 2>&1); then
        debug_msg "Command succeeded. Output:"
        echo "$output" | tee -a "${LOG_FILE}"
    else
        error_msg "Command failed. Output:"
        echo "$output" | tee -a "${LOG_FILE}"
        return 1
    fi
}

# Linux workload template
LINUX_WORKLOAD_TEMPLATE=$(cat << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: linux-webserver
  labels:
    app: linux-webserver
spec:
  ports:
  - port: 8080
    targetPort: 8080
  selector:
    app: linux-webserver
  type: LoadBalancer
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: linux-webserver
  name: linux-webserver
spec:
  selector:
    matchLabels:
      app: linux-webserver
  replicas: 1
  template:
    metadata:
      labels:
        app: linux-webserver
      name: linux-webserver
    spec:
      containers:
      - name: linux-webserver
        image: ${LINUX_IMAGE}
        ports:
        - containerPort: 8080
EOF
)

# Windows workload template
WINDOWS_WORKLOAD_TEMPLATE=$(cat << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: win-webserver
  labels:
    app: win-webserver
spec:
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: win-webserver
  type: LoadBalancer
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: win-webserver
  name: win-webserver
spec:
  selector:
    matchLabels:
      app: win-webserver
  replicas: 1
  template:
    metadata:
      labels:
        app: win-webserver
      name: win-webserver
    spec:
      tolerations:
      - key: "os"
        value: "Windows"
        effect: "NoSchedule"
      containers:
      - name: win-webserver
        image: ${WINDOWS_IMAGE}
        imagePullPolicy: IfNotPresent
        command:
        - pwsh.exe
        - -command
        - ${WINDOWS_COMMAND}
        securityContext:
          runAsNonRoot: false
          windowsOptions:
            runAsUserName: "ContainerAdministrator"
      nodeSelector:
        beta.kubernetes.io/os: windows
      os:
        name: windows
EOF
)

# Windows PowerShell command for web server
WINDOWS_PS_COMMAND='$listener = New-Object System.Net.HttpListener; $listener.Prefixes.Add('\''http://*:80/'\''); $listener.Start();Write-Host('\''Listening at http://*:80/'\''); while ($listener.IsListening) { $context = $listener.GetContext(); $response = $context.Response; $content='\''<html><body><H1>Windows Container Web Server</H1></body></html>'\''; $buffer = [System.Text.Encoding]::UTF8.GetBytes($content); $response.ContentLength64 = $buffer.Length; $response.OutputStream.Write($buffer, 0, $buffer.Length); $response.Close(); };'

# Check if the cluster is disconnected
function is_disconnected() {
    debug_msg "Checking if cluster is disconnected..."
    local output
    if ! output=$(oc get configmap ${WINC_TEST_CM} -n ${DEFAULT_NAMESPACE} -o=yaml 2>&1); then
        debug_msg "Failed to get configmap ${WINC_TEST_CM}: ${output}"
        return 1
    fi
    
    if echo "$output" | grep -q "<.*_disconnected_image>"; then
        debug_msg "Found placeholder values in configmap"
        return 1
    fi

    local required_keys=("primary_windows_container_disconnected_image" "linux_container_disconnected_image")
    for key in "${required_keys[@]}"; do
        if ! echo "$output" | grep -q "${key}"; then
            debug_msg "Missing required key in configmap: ${key}"
            return 1
        fi
    done

    debug_msg "Cluster is disconnected"
    return 0
}

# Get configmap data
function get_configmap_data() {
    local key=$1
    debug_msg "Getting configmap data for key: ${key}"
    local value
    if ! value=$(oc get configmap ${WINC_TEST_CM} -n ${DEFAULT_NAMESPACE} -o=jsonpath="{.data.${key}}" 2>&1); then
        error_msg "Failed to get configmap data for key ${key}: ${value}"
        return 1
    fi
    echo "${value}"
}

# Create Linux workload
function create_linux_workload() {
    local linux_image="${1}"
    debug_msg "Creating Linux workload with image: ${linux_image}"
    
    local temp_file=$(mktemp)
    export LINUX_IMAGE="${linux_image}"
    echo "${LINUX_WORKLOAD_TEMPLATE}" | envsubst > "${temp_file}"
    
    if ! oc create -f "${temp_file}"; then
        error_msg "Failed to create Linux workload"
        rm "${temp_file}"
        return 1
    fi
    
    rm "${temp_file}"
    return 0
}

# Create Windows workload
function create_windows_workload() {
    local windows_image="${1}"
    local is_disconnected="${2:-false}"
    debug_msg "Creating Windows workload with image: ${windows_image}"
    
    local temp_file=$(mktemp)
    export WINDOWS_IMAGE="${windows_image}"
    export WINDOWS_COMMAND="${WINDOWS_PS_COMMAND}"
    echo "${WINDOWS_WORKLOAD_TEMPLATE}" | envsubst > "${temp_file}"
    
    if [ "${is_disconnected}" = true ]; then
        debug_msg "Adding imagePullSecrets for disconnected environment"
        sed -i '/os:/i\      imagePullSecrets:\n      - name: pull-secret' "${temp_file}"
    fi
    
    if ! oc create -f "${temp_file}"; then
        error_msg "Failed to create Windows workload"
        rm "${temp_file}"
        return 1
    fi
    
    rm "${temp_file}"
    return 0
}

# Create configmap for Windows container testing
function create_winc_test_configmap() {
    local primary_windows_image="${1}"
    local primary_windows_container_image="${2}"
    local is_disconnected="${3:-false}"
    
    local create_cmd="oc create configmap ${WINC_TEST_CM} -n ${DEFAULT_NAMESPACE}"
    create_cmd+=" --from-literal=primary_windows_image=${primary_windows_image}"
    create_cmd+=" --from-literal=primary_windows_container_image=${primary_windows_container_image}"
    
    if [ "${is_disconnected}" = true ]; then
        local disconnected_windows_image=$(get_configmap_data "primary_windows_container_disconnected_image")
        local disconnected_linux_image=$(get_configmap_data "linux_container_disconnected_image")
        
        create_cmd+=" --from-literal=primary_windows_container_disconnected_image=${disconnected_windows_image}"
        create_cmd+=" --from-literal=linux_container_disconnected_image=${disconnected_linux_image}"
    fi
    
    if ! eval "${create_cmd}"; then
        error_msg "Failed to create configmap"
        return 1
    fi
}

# Create workloads (both Windows and Linux)
function create_workloads() {
    local container_image="${1}"
    local is_disconnected="${2:-false}"
    
    # Create namespace
    if ! oc new-project ${DEFAULT_NAMESPACE}; then
        error_msg "Failed to create namespace ${DEFAULT_NAMESPACE}"
        return 1
    fi
    
    # Set namespace security labels
    if ! oc label namespace ${DEFAULT_NAMESPACE} \
        security.openshift.io/scc.podSecurityLabelSync=false \
        pod-security.kubernetes.io/enforce=privileged --overwrite; then
        error_msg "Failed to set namespace security labels"
        return 1
    fi
    
    # Create Windows workload
    if ! create_windows_workload "${container_image}" "${is_disconnected}"; then
        error_msg "Failed to create Windows workload"
        return 1
    fi
    
    # Wait for Windows workload
    if ! oc wait deployment win-webserver -n ${DEFAULT_NAMESPACE} --for condition=Available=True --timeout=5m; then
        error_msg "Windows workload did not become ready within timeout"
        return 1
    fi
    
    # Create Linux workload
    local linux_image
    if [ "${is_disconnected}" = true ]; then
        linux_image=$(get_configmap_data "linux_container_disconnected_image")
    else
        linux_image="quay.io/openshifttest/hello-openshift:multiarch-winc"
    fi
    
    if ! create_linux_workload "${linux_image}"; then
        error_msg "Failed to create Linux workload"
        return 1
    fi
    
    # Wait for Linux workload
    if ! oc wait deployment linux-webserver -n ${DEFAULT_NAMESPACE} --for condition=Available=True --timeout=5m; then
        error_msg "Linux workload did not become ready within timeout"
        return 1
    fi
}

# Main execution
debug_msg "Script started"

# Get IAAS platform
if ! IAAS_PLATFORM=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.type}" | tr '[:upper:]' '[:lower:]'); then
    error_msg "Failed to get IAAS platform information"
    exit 1
fi

# Get Windows worker information
if ! winworker_machineset_name=$(oc get machineset -n openshift-machine-api -o json | jq -r '.items[] | select(.metadata.name | test("win")).metadata.name'); then
    error_msg "Failed to get Windows worker machineset name"
    exit 1
fi

if ! winworker_machineset_replicas=$(oc get machineset -n openshift-machine-api "${winworker_machineset_name}" -o jsonpath="{.spec.replicas}"); then
    error_msg "Failed to get Windows worker machineset replicas"
    exit 1
fi

# Wait for Windows nodes
while true; do
    ready_replicas=$(oc -n openshift-machine-api get machineset/"${winworker_machineset_name}" -o 'jsonpath={.status.readyReplicas}')
    if [ "${ready_replicas:-0}" = "${winworker_machineset_replicas}" ]; then
        break
    fi
    sleep 10
done

if ! oc wait nodes -l kubernetes.io/os=windows --for condition=Ready=True --timeout=15m; then
    error_msg "Windows nodes did not become ready within timeout"
    exit 1
fi

# Check if the environment is disconnected
IS_DISCONNECTED=$(is_disconnected && echo true || echo false)

# Main workflow execution
if [ "${IS_DISCONNECTED}" = true ]; then
    debug_msg "Running in disconnected environment"
    CONTAINER_IMAGE=$(get_configmap_data "primary_windows_container_disconnected_image")
else
    debug_msg "Running in connected environment"
    CONTAINER_IMAGE="mcr.microsoft.com/windows/servercore:ltsc2019"
fi

create_workloads "${CONTAINER_IMAGE}" "${IS_DISCONNECTED}"
