#!/bin/bash

# Namespace protection and validation

WINCNAMESPACE="winc-test"

# Enable strict error handling and debug mode
set -o errexit    
set -o nounset    
set -o pipefail   
set -x            

script_dir=$(dirname "$0")
echo "📂 Script directory: $script_dir"

MIRROR_REGISTRY_FILE="${SHARED_DIR}/mirror_registry_url"
if [ -f $MIRROR_REGISTRY_FILE ]; then
  DISCONNECTED_REGISTRY=$(head -n 1 $MIRROR_REGISTRY_FILE)
  export DISCONNECTED_REGISTRY
  echo "Using mirror registry: $DISCONNECTED_REGISTRY"
fi

# Define image paths
PRIMARY_WINDOWS_CONTAINER_IMAGE="mcr.microsoft.com/powershell:lts-nanoserver-ltsc2022"
PRIMARY_WINDOWS_IMAGE="windows-golden-images/windows-server-2022-template-qe"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"

# Function to print log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to verify cluster access
verify_cluster_access() {
    if ! oc whoami &>/dev/null; then
        echo "ERROR: Not logged into OpenShift cluster"
        exit 1
    fi
    log_message "Successfully verified cluster access"
}

# Function to create or switch to namespace with error handling
create_or_switch_to_namespace() {
    echo "Ensuring the ${WINCNAMESPACE} namespace exists..."
    if ! oc get namespace ${WINCNAMESPACE} &>/dev/null; then
        echo "Namespace ${WINCNAMESPACE} does not exist. Creating it..."
        if ! oc new-project ${WINCNAMESPACE}; then
            echo "WARNING: Failed to create the ${WINCNAMESPACE} project"
            return 1
        fi
    else
        echo "Namespace ${WINCNAMESPACE} already exists. Switching to it..."
        if ! oc project ${WINCNAMESPACE}; then
            echo "WARNING: Failed to switch to the ${WINCNAMESPACE} project"
            return 1
        fi
    fi
    
    # Set pod security configuration
    oc label namespace ${WINCNAMESPACE} security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged --overwrite || true
    echo "Namespace ${WINCNAMESPACE} is ready."
}

# Function to create Windows workloads
create_windows_workloads() {
  log_message "Creating Windows workloads..."
  create_or_switch_to_namespace

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
    if [ X$(oc get deployment win-webserver -o=jsonpath={.status.readyReplicas}) == X"5" ]; then
      echo "Windows workload is READY"
      break
    fi
    if [ "$loops" -ge "$max_loops" ]; then
      echo "Timeout: Windows workload is not READY"
      exit 1
    fi
    loops=$((loops + 1))
    echo "Waiting for Windows workload to be ready... (${loops}/${max_loops})"
    sleep $sleep_seconds
  done
}

# Modified Linux workloads function with error handling
create_linux_workloads() {
    log_message "Creating Linux workloads..."
    create_or_switch_to_namespace || true

    # Apply deployments with error handling
    if ! oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: linux-webserver-ubi
  namespace: ${WINCNAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: linux-webserver-ubi
  template:
    metadata:
      labels:
        app: linux-webserver-ubi
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
        log_message "WARNING: Failed to create linux-webserver-ubi deployment"
    fi

    # Wait for Linux workload with timeout but don't fail the script
    loops=0
    max_loops=15
    sleep_seconds=20
    while true; do
        ready_replicas=$(oc get deployment linux-webserver-ubi -n ${WINCNAMESPACE} -o=jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
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
    
    # Execute functions with error handling
    create_or_switch_to_namespace

create_linux_workloads
LINUX_STATUS=$?
if [ $LINUX_STATUS -ne 0 ]; then
    echo "Warning: Linux workloads creation failed with status $LINUX_STATUS"
fi

create_windows_workloads
WINDOWS_STATUS=$?
if [ $WINDOWS_STATUS -ne 0 ]; then
    echo "Warning: Windows workloads creation failed with status $WINDOWS_STATUS"
fi

if [ $LINUX_STATUS -ne 0 ] && [ $WINDOWS_STATUS -ne 0 ]; then
    echo "Both workload creations failed"
    exit 1
fi
    log_message "Script execution completed"

