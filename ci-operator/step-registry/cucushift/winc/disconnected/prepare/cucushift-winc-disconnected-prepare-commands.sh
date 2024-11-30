#!/bin/bash

# Namespace protection and validation
if [[ -n "${NAMESPACE:-}" ]]; then
    echo "WARNING: NAMESPACE is already set to '${NAMESPACE}'"
    echo "Script requires NAMESPACE=winc-test"
    echo "Current environment may interfere with script execution"
    exit 1
fi
NAMESPACE="winc-test"

# Enable strict error handling and debug mode
set -o errexit    
set -o nounset    
set -o pipefail   
set -x            

script_dir=$(dirname "$0")
work_dir=$PWD

# Get registry hostname from environment variable or use default value
DISCONNECTED_REGISTRY=${REGISTRY_HOST:-"bastion.mirror-registry.qe.devcluster.openshift.com:5000"}

# Or directly get from existing configmap if it exists
if oc get configmap winc-test-config -n ${NAMESPACE} &>/dev/null; then
    DISCONNECTED_REGISTRY=$(oc get configmap winc-test-config -n ${NAMESPACE} -o jsonpath='{.data.primary_windows_container_disconnected_image}' | awk -F/ '{print $1}')
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
    echo "Ensuring the ${NAMESPACE} namespace exists..."
    if ! oc get namespace ${NAMESPACE} &>/dev/null; then
        echo "Namespace ${NAMESPACE} does not exist. Creating it..."
        if ! oc new-project ${NAMESPACE}; then
            echo "WARNING: Failed to create the ${NAMESPACE} project"
            return 1
        fi
    else
        echo "Namespace ${NAMESPACE} already exists. Switching to it..."
        if ! oc project ${NAMESPACE}; then
            echo "WARNING: Failed to switch to the ${NAMESPACE} project"
            return 1
        fi
    fi
    
    # Set pod security configuration
    oc label namespace ${NAMESPACE} security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged --overwrite || true
    echo "Namespace ${NAMESPACE} is ready."
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
  namespace: ${NAMESPACE}
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
        image: ${DISCONNECTED_REGISTRY}/ubi8/ubi-minimal:latest
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
        ready_replicas=$(oc get deployment linux-webserver-ubi -n ${NAMESPACE} -o=jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
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
main() {
    log_message "Starting script execution..."
    verify_cluster_access
    
    # Execute functions with error handling
    create_or_switch_to_namespace || true
    create_linux_workloads || true
    
    log_message "Script execution completed"
}

# Execute main function
main