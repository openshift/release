#!/bin/bash

# Namespace protection and validation
WINCNAMESPACE="winc-test"

# Enable strict error handling and debug mode
set -x
set +e  

script_dir=$(dirname "$0")

# Registry configuration with enhanced debugging
MIRROR_REGISTRY_FILE="${SHARED_DIR}/mirror_registry_url"
if [ -f $MIRROR_REGISTRY_FILE ]; then
    DISCONNECTED_REGISTRY=$(head -n 1 $MIRROR_REGISTRY_FILE)
    export DISCONNECTED_REGISTRY
    echo "Using mirror registry: $DISCONNECTED_REGISTRY"
    echo "Full contents of mirror registry file:"
    cat $MIRROR_REGISTRY_FILE
else
    echo "WARNING: Mirror registry file not found at $MIRROR_REGISTRY_FILE"
fi

# Add registry debug information
debug_registry_info() {
    log_message "Registry Debug Information:"
    log_message "DISCONNECTED_REGISTRY=${DISCONNECTED_REGISTRY:-not_set}"
    if [ -n "${DISCONNECTED_REGISTRY:-}" ]; then
        log_message "Testing registry connectivity..."
        if curl -k -s "${DISCONNECTED_REGISTRY}" > /dev/null; then
            log_message "Registry is accessible"
        else
            log_message "WARNING: Registry might not be accessible"
        fi
    fi
}

# Enhanced logging function
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /tmp/winc-test-debug.log
}

# Function to dump deployment details
dump_deployment_details() {
    local deployment_name=$1
    log_message "Dumping full details for deployment: ${deployment_name}"
    log_message "--- Deployment YAML ---"
    oc get deployment ${deployment_name} -n ${WINCNAMESPACE} -oyaml | tee -a /tmp/winc-test-debug.log
    log_message "--- Deployment Events ---"
    oc get events -n ${WINCNAMESPACE} --field-selector involvedObject.name=${deployment_name} | tee -a /tmp/winc-test-debug.log
    log_message "--- Pod Details ---"
    oc get pods -n ${WINCNAMESPACE} -l app=${deployment_name} -oyaml | tee -a /tmp/winc-test-debug.log
    log_message "--- Pod Logs ---"
    for pod in $(oc get pods -n ${WINCNAMESPACE} -l app=${deployment_name} -o jsonpath='{.items[*].metadata.name}'); do
        log_message "Logs for pod: ${pod}"
        oc logs ${pod} -n ${WINCNAMESPACE} || true
    done
}

# Modified create_windows_workloads function
create_windows_workloads() {
    log_message "Creating Windows workloads..."
    create_or_switch_to_namespace

    # Debug: Show node information
    log_message "Available nodes and their labels:"
    oc get nodes --show-labels
    
    # Create configmap before deployment
    create_winc_test_configmap "${PRIMARY_WINDOWS_IMAGE}" "${PRIMARY_WINDOWS_CONTAINER_IMAGE}"

    log_message "Deploying Windows workload with image: ${PRIMARY_WINDOWS_CONTAINER_IMAGE}"
    
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

    # Immediately dump the created deployment
    log_message "Initial deployment state:"
    dump_deployment_details "win-webserver"

    # Wait for Windows workload to be ready with enhanced debugging
    loops=0
    max_loops=15
    sleep_seconds=20
    while true; do
        available_replicas=$(oc get deployment win-webserver -n ${WINCNAMESPACE} -o jsonpath='{.status.availableReplicas}')
        log_message "Current available replicas: ${available_replicas:-0} (target: 5)"
        
        if [ X"${available_replicas}" == X"5" ]; then
            log_message "Windows workload is READY"
            dump_deployment_details "win-webserver"
            break
        fi
        
        if [ "$loops" -ge "$max_loops" ]; then
            log_message "Timeout: Windows workload is not READY"
            log_message "Final deployment state:"
            dump_deployment_details "win-webserver"
            exit 1
        fi
        
        loops=$((loops + 1))
        log_message "Waiting for Windows workload to be ready... (${loops}/${max_loops})"
        log_message "Current deployment status:"
        oc get deployment win-webserver -n ${WINCNAMESPACE} -o wide
        log_message "Pod status:"
        oc get pods -n ${WINCNAMESPACE} -l app=win-webserver -o wide
        sleep $sleep_seconds
    done
}

# Modified create_linux_workloads function
create_linux_workloads() {
    log_message "Creating Linux workloads..."
    log_message "Using DISCONNECTED_REGISTRY: ${DISCONNECTED_REGISTRY:-not_set}"
    create_or_switch_to_namespace || true

    log_message "Deploying Linux webserver..."
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
        return 1
    fi

    # Immediately dump the created deployment
    log_message "Initial Linux deployment state:"
    dump_deployment_details "linux-webserver"

    # Wait for Linux workload with enhanced debugging
    loops=0
    max_loops=15
    sleep_seconds=20
    while true; do
        ready_replicas=$(oc get deployment linux-webserver -n ${WINCNAMESPACE} -o=jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        log_message "Current ready replicas: ${ready_replicas} (target: 1)"
        
        if [ "X${ready_replicas}" == "X1" ]; then
            log_message "Linux workload is READY"
            dump_deployment_details "linux-webserver"
            break
        fi
        
        if [ "$loops" -ge "$max_loops" ]; then
            log_message "WARNING: Timeout waiting for Linux workload"
            log_message "Final deployment state:"
            dump_deployment_details "linux-webserver"
            break
        fi
        
        log_message "Linux workload is not READY yet, wait $sleep_seconds seconds"
        log_message "Current deployment status:"
        oc get deployment linux-webserver -n ${WINCNAMESPACE} -o wide
        log_message "Pod status:"
        oc get pods -n ${WINCNAMESPACE} -l app=linux-webserver -o wide
        ((loops++))
        sleep $sleep_seconds
    done
}

# Main execution with enhanced debugging
log_message "Starting script execution..."
log_message "Script directory: ${script_dir}"
debug_registry_info
verify_cluster_access
create_or_switch_to_namespace
create_linux_workloads
create_windows_workloads

# Final status dump
log_message "Final deployment status:"
oc get deployments -n ${WINCNAMESPACE} -o wide
oc get pods -n ${WINCNAMESPACE} -o wide
log_message "Script completed"