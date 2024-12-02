#!/bin/bash

# Enable debug mode and disable immediate exit on error
set -x
set +e  

# Namespace for Windows Container tests
WINCNAMESPACE="winc-test"

# Define image paths
PRIMARY_WINDOWS_CONTAINER_IMAGE="mcr.microsoft.com/powershell:lts-nanoserver-ltsc2022"
PRIMARY_WINDOWS_IMAGE="windows-golden-images/windows-server-2022-template-qe"
export PRIMARY_WINDOWS_CONTAINER_IMAGE
export PRIMARY_WINDOWS_IMAGE
script_dir=$(dirname "$0")

# Function for logging messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /tmp/winc-test-debug.log
}

# Function to verify OpenShift cluster access
verify_cluster_access() {
    log_message "Verifying cluster access..."
    if ! oc whoami &>/dev/null; then
        log_message "ERROR: Not logged into OpenShift cluster"
        exit 1
    fi
}

# Function to create or switch to the test namespace
create_or_switch_to_namespace() {
    log_message "Creating/switching to namespace ${WINCNAMESPACE}..."
    if ! oc get namespace "${WINCNAMESPACE}" &>/dev/null; then
        if ! oc create namespace "${WINCNAMESPACE}"; then
            log_message "ERROR: Failed to create namespace ${WINCNAMESPACE}"
            return 1
        fi
    fi
    if ! oc project "${WINCNAMESPACE}"; then
        log_message "ERROR: Failed to switch to namespace ${WINCNAMESPACE}"
        return 1
    fi
    return 0
}

# Function to create ConfigMap for Windows test configuration
create_winc_test_configmap() {
    local windows_image="$1"
    local container_image="$2"
    
    log_message "Creating ConfigMap for Windows test..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: winc-test-config
  namespace: ${WINCNAMESPACE}
data:
  windows_image: "${windows_image}"
  container_image: "${container_image}"
EOF

    # Verify ConfigMap creation
    if ! oc get configmap winc-test-config -n "${WINCNAMESPACE}" &>/dev/null; then
        log_message "ERROR: Failed to create ConfigMap winc-test-config"
        return 1
    fi
    
    log_message "ConfigMap winc-test-config created successfully"
    return 0
}

# Read and validate mirror registry URL
MIRROR_REGISTRY_FILE="${SHARED_DIR}/mirror_registry_url"
#MIRROR_REGISTRY_FILE="/var/run/secrets/ci.openshift.io/multi-stage/mirror_registry_url"
if [ -f "$MIRROR_REGISTRY_FILE" ]; then
    DISCONNECTED_REGISTRY=$(head -n 1 "$MIRROR_REGISTRY_FILE" | tr -d '[:space:]')
    if [ -n "$DISCONNECTED_REGISTRY" ]; then
        export DISCONNECTED_REGISTRY
        log_message "Using mirror registry: $DISCONNECTED_REGISTRY"
    else
        log_message "ERROR: Mirror registry URL is empty"
        exit 1
    fi
else
    log_message "ERROR: Mirror registry file not found at $MIRROR_REGISTRY_FILE"
    exit 1
fi

# Function to debug registry information
debug_registry_info() {
    log_message "Registry Debug Information:"
    log_message "DISCONNECTED_REGISTRY=${DISCONNECTED_REGISTRY:-not_set}"
    if [ -n "${DISCONNECTED_REGISTRY:-}" ]; then
        log_message "Testing registry connectivity..."
        if curl -k -s "https://${DISCONNECTED_REGISTRY}/v2/" > /dev/null 2>&1; then
            log_message "Registry is accessible"
        else
            log_message "WARNING: Registry might not be accessible"
        fi
    fi
}

# Function to dump deployment details for debugging
dump_deployment_details() {
    local deployment_name="$1"
    
    log_message "Dumping full details for deployment: ${deployment_name}"
    log_message "--- Deployment YAML ---"
    oc get deployment "${deployment_name}" -n "${WINCNAMESPACE}" -oyaml | tee -a /tmp/winc-test-debug.log
    
    log_message "--- Deployment Events ---"
    oc get events -n "${WINCNAMESPACE}" --field-selector "involvedObject.name=${deployment_name}" | tee -a /tmp/winc-test-debug.log
    
    log_message "--- Pod Details ---"
    oc get pods -n "${WINCNAMESPACE}" -l "app=${deployment_name}" -oyaml | tee -a /tmp/winc-test-debug.log
    
    log_message "--- Pod Logs ---"
    local pods
    pods=$(oc get pods -n "${WINCNAMESPACE}" -l "app=${deployment_name}" -o jsonpath='{.items[*].metadata.name}')
    for pod in $pods; do
        log_message "Logs for pod: ${pod}"
        oc logs "${pod}" -n "${WINCNAMESPACE}" || true
    done
}

# Function to create Windows workloads
create_windows_workloads() {
    log_message "Creating Windows workloads..."
    create_or_switch_to_namespace || return 1

    log_message "Deploying Windows workload with image: ${PRIMARY_WINDOWS_CONTAINER_IMAGE}"
    
    # Create Windows deployment
    if ! oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: win-webserver
  namespace: ${WINCNAMESPACE}
spec:
  replicas: 5
  selector:
    matchLabels:
      app: win-webserver
  template:
    metadata:
      labels:
        app: win-webserver
    spec:
      nodeSelector:
        kubernetes.io/os: windows
      tolerations:
      - key: "os"
        value: "Windows"
        effect: "NoSchedule"
      imagePullSecrets:
      - name: local-registry-secret
      containers:
      - name: win-webserver
        image: ${PRIMARY_WINDOWS_CONTAINER_IMAGE}
        command: ["pwsh.exe"]
        args: ["-Command", "while(\$true) { Write-Host 'Windows container is running...'; Start-Sleep -Seconds 30 }"]
        ports:
        - containerPort: 80
        volumeMounts:
        - name: config-volume
          mountPath: /config
      volumes:
      - name: config-volume
        configMap:
          name: winc-test-config
EOF
    then
        log_message "ERROR: Failed to create Windows deployment"
        return 1
    fi

    # Wait for Windows workload to be ready
    local loops=0
    local max_loops=15
    local sleep_seconds=20
    while true; do
        local available_replicas
        available_replicas=$(oc get deployment win-webserver -n "${WINCNAMESPACE}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
        log_message "Current available replicas: ${available_replicas} (target: 5)"
        
        if [ "${available_replicas}" == "5" ]; then
            log_message "Windows workload is READY"
            dump_deployment_details "win-webserver"
            return 0
        fi
        
        if [ "$loops" -ge "$max_loops" ]; then
            log_message "Timeout: Windows workload is not READY"
            dump_deployment_details "win-webserver"
            return 1
        fi
        
        ((loops++))
        log_message "Waiting for Windows workload to be ready... (${loops}/${max_loops})"
        oc get deployment win-webserver -n "${WINCNAMESPACE}" -o wide
        oc get pods -n "${WINCNAMESPACE}" -l app=win-webserver -o wide
        sleep "$sleep_seconds"
    done
}

# Function to create Linux workloads
create_linux_workloads() {
    log_message "Creating Linux workloads..."
    log_message "Using DISCONNECTED_REGISTRY: ${DISCONNECTED_REGISTRY:-not_set}"
    
    if ! create_or_switch_to_namespace; then
        log_message "ERROR: Failed to create/switch namespace"
        return 1
    fi

    if [ -z "${DISCONNECTED_REGISTRY:-}" ]; then
        log_message "ERROR: DISCONNECTED_REGISTRY is not set"
        return 1
    fi

    local linux_image="${DISCONNECTED_REGISTRY}/hello-openshift:multiarch-winc"
    log_message "Using Linux image: ${linux_image}"

    # Create Linux deployment
    if ! oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: linux-webserver
  namespace: ${WINCNAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: linux-webserver
  template:
    metadata:
      labels:
        app: linux-webserver
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: webserver
        image: ${linux_image}
        command: ["sleep"]
        args: ["infinity"]
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          runAsNonRoot: true
EOF
    then
        log_message "ERROR: Failed to create linux-webserver deployment"
        return 1
    fi

    # Wait for Linux workload to be ready
    local loops=0
    local max_loops=15
    local sleep_seconds=20
    while true; do
        local ready_replicas
        ready_replicas=$(oc get deployment linux-webserver -n "${WINCNAMESPACE}" -o=jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        log_message "Current ready replicas: ${ready_replicas} (target: 1)"
        
        if [ "${ready_replicas}" == "1" ]; then
            log_message "Linux workload is READY"
            dump_deployment_details "linux-webserver"
            return 0
        fi
        
        if [ "$loops" -ge "$max_loops" ]; then
            log_message "ERROR: Timeout waiting for Linux workload"
            dump_deployment_details "linux-webserver"
            return 1
        fi
        
        ((loops++))
        log_message "Linux workload is not READY yet, wait $sleep_seconds seconds"
        oc get deployment linux-webserver -n "${WINCNAMESPACE}" -o wide
        oc get pods -n "${WINCNAMESPACE}" -l app=linux-webserver -o wide
        sleep "$sleep_seconds"
    done
}

# Main execution function
main() {
    log_message "Starting script execution..."
    log_message "Script directory: ${script_dir}"
    
    verify_cluster_access
    debug_registry_info
    
    # Validate required environment variables
    if [ -z "${PRIMARY_WINDOWS_IMAGE:-}" ]; then
        log_message "ERROR: PRIMARY_WINDOWS_IMAGE environment variable is not set"
        exit 1
    fi
    if [ -z "${PRIMARY_WINDOWS_CONTAINER_IMAGE:-}" ]; then
        log_message "ERROR: PRIMARY_WINDOWS_CONTAINER_IMAGE environment variable is not set"
        exit 1
    fi
    
    # Create namespace first
    create_or_switch_to_namespace || exit 1
    
    # Create ConfigMap before workloads
    if ! create_winc_test_configmap "${PRIMARY_WINDOWS_IMAGE}" "${PRIMARY_WINDOWS_CONTAINER_IMAGE}"; then
        log_message "ERROR: Failed to create required ConfigMap"
        exit 1
    fi
    
    # Create workloads
    create_linux_workloads || exit 1
    create_windows_workloads || exit 1

    # Final status dump
    log_message "Final deployment status:"
    oc get deployments -n "${WINCNAMESPACE}" -o wide
    oc get pods -n "${WINCNAMESPACE}" -o wide
    log_message "Script completed successfully"
}

# Execute main function with logging
main 2>&1 | tee -a /tmp/winc-test-debug.log