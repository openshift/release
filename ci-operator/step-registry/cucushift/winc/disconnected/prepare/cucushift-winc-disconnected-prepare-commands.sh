#!/bin/bash

# Namespace protection and validation
WINCNAMESPACE="winc-test"

# Enable strict error handling and debug mode
set -o nounset
set -o pipefail
set -x

script_dir=$(dirname "$0")

# Registry configuration
MIRROR_REGISTRY_FILE="${SHARED_DIR}/mirror_registry_url"
if [ -f $MIRROR_REGISTRY_FILE ]; then
    DISCONNECTED_REGISTRY=$(head -n 1 $MIRROR_REGISTRY_FILE)
    export DISCONNECTED_REGISTRY
    echo "Using mirror registry: $DISCONNECTED_REGISTRY"
fi

# Define image paths
PRIMARY_WINDOWS_CONTAINER_IMAGE="mcr.microsoft.com/powershell:lts-nanoserver-ltsc2022"
PRIMARY_WINDOWS_IMAGE="windows-golden-images/windows-server-2022-template-qe-20241104"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"

# Function to print log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to verify cluster access
verify_cluster_access() {
    if ! oc whoami &>/dev/null; then
        log_message "ERROR: Not logged into OpenShift cluster"
        exit 1
    fi
    log_message "Successfully verified cluster access"
}

# Function to create or switch to namespace with error handling
create_or_switch_to_namespace() {
    log_message "Ensuring the ${WINCNAMESPACE} namespace exists..."
    if ! oc get namespace ${WINCNAMESPACE} &>/dev/null; then
        log_message "Creating namespace ${WINCNAMESPACE}..."
        if ! oc new-project ${WINCNAMESPACE}; then
            log_message "WARNING: Failed to create the ${WINCNAMESPACE} project"
            return 1
        fi
    else
        log_message "Switching to namespace ${WINCNAMESPACE}..."
        if ! oc project ${WINCNAMESPACE}; then
            log_message "WARNING: Failed to switch to the ${WINCNAMESPACE} project"
            return 1
        fi
    fi
    
    # Set pod security configuration
    oc label namespace ${WINCNAMESPACE} security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged --overwrite || true
    log_message "Namespace ${WINCNAMESPACE} is ready"
}

# Function to create Windows config map
create_winc_test_configmap() {
    log_message "Creating configmap with Windows image information..."
    if ! oc create configmap winc-test-config -n ${WINCNAMESPACE} \
        --from-literal=primary_windows_image="${1}" \
        --from-literal=primary_windows_container_image="${2}"; then
        log_message "WARNING: Failed to create configmap"
        return 1
    fi

    # Display pods and configmap for verification
    log_message "Verifying deployment status:"
    oc get pod -owide -n ${WINCNAMESPACE}
    oc get cm winc-test-config -oyaml -n ${WINCNAMESPACE}
}

# Function to create Windows workloads
create_windows_workloads() {
    log_message "Creating Windows workloads..."
    create_or_switch_to_namespace

    # Create configmap before deployment
    create_winc_test_configmap "${PRIMARY_WINDOWS_IMAGE}" "${PRIMARY_WINDOWS_CONTAINER_IMAGE}"

    cat <<EOF | oc apply -f -
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

    # Wait for Windows workload to be ready
    loops=0
    max_loops=15
    sleep_seconds=20
    while true; do
        if [ X$(oc get deployment win-webserver -n ${WINCNAMESPACE} -o jsonpath='{.status.availableReplicas}') == X"5" ]; then
            log_message "Windows workload is READY"
            break
        fi
        if [ "$loops" -ge "$max_loops" ]; then
            log_message "Timeout: Windows workload is not READY"
            exit 1
        fi
        loops=$((loops + 1))
        log_message "Waiting for Windows workload to be ready... (${loops}/${max_loops})"
        sleep $sleep_seconds
    done
}

# Function to create Linux workloads
create_linux_workloads() {
    log_message "Creating Linux workloads..."
    create_or_switch_to_namespace || true

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
        image: ${DISCONNECTED_REGISTRY}/hello-openshift:multiarch-winc
        command: ["sleep"]
        args: ["infinity"]
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          runAsNonRoot: true
EOF
    then
        log_message "WARNING: Failed to create linux-webserver deployment"
    fi

    # Wait for Linux workload with timeout
    loops=0
    max_loops=15
    sleep_seconds=20
    while true; do
        ready_replicas=$(oc get deployment linux-webserver -n ${WINCNAMESPACE} -o=jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "X${ready_replicas}" == "X1" ]; then
            log_message "Linux workload is READY"
            break
        fi
        if [ "$loops" -ge "$max_loops" ]; then
            log_message "WARNING: Timeout waiting for Linux workload"
            break
        fi
        log_message "Linux workload is not READY yet, wait $sleep_seconds seconds"
        ((loops++))
        sleep $sleep_seconds
    done
}

# Main execution
log_message "Starting script execution..."
verify_cluster_access
create_or_switch_to_namespace
create_linux_workloads
create_windows_workloads