#!/bin/bash
# Enable strict error handling and debug mode
set -o errexit    # Exit immediately if a command exits with a non-zero status
set -o nounset    # Treat unset variables as an error
set -o pipefail   # Pipeline fails on any command failure
set -x            # Print commands and their arguments as they are executed
script_dir=$(dirname "$0")
work_dir=$PWD
NAMESPACE="winc-test"

# Get mirror registry hostname from route
DISCONNECTED_REGISTRY=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}' | sed 's/console-openshift-console/bastion.mirror-registry.qe.devcluster.openshift.com:5000/')

# Or directly get from existing configmap if it exists
if oc get configmap winc-test-config -n winc-test &>/dev/null; then
    DISCONNECTED_REGISTRY=$(oc get configmap winc-test-config -n winc-test -o jsonpath='{.data.primary_windows_container_disconnected_image}' | awk -F/ '{print $1}')
fi

# Define image paths
LINUX_CONTAINER_IMAGE="${DISCONNECTED_REGISTRY}/hello-openshift:multiarch-winc"
PRIMARY_WINDOWS_CONTAINER_IMAGE="${DISCONNECTED_REGISTRY}/powershell:lts-nanoserver-ltsc2022"
PRIMARY_WINDOWS_IMAGE="windows-golden-images/windows-server-2022-template-qe"

# Function to print log messages with timestamp
log_message() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to create or switch to namespace
create_or_switch_to_namespace() {
  echo "Ensuring the ${NAMESPACE} namespace exists..."
  if ! oc get namespace ${NAMESPACE} &>/dev/null; then
    echo "Namespace ${NAMESPACE} does not exist. Creating it..."
    oc new-project ${NAMESPACE} || { echo "Failed to create the ${NAMESPACE} project."; exit 1; }
  else
    echo "Namespace ${NAMESPACE} already exists. Switching to it..."
    oc project ${NAMESPACE} || { echo "Failed to switch to the ${NAMESPACE} project."; exit 1; }
  fi
  # Set pod security configuration
  oc label namespace ${NAMESPACE} security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged --overwrite
  echo "Namespace ${NAMESPACE} is ready."
}

# Function to create ConfigMap with container configurations
create_winc_test_configmap() {
  log_message "Creating winc-test ConfigMap..."
  create_or_switch_to_namespace
  
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: winc-test-config
  namespace: ${NAMESPACE}
data:
  linux_container_disconnected_image: "${LINUX_CONTAINER_IMAGE}"
  primary_windows_container_disconnected_image: "${PRIMARY_WINDOWS_CONTAINER_IMAGE}"
  primary_windows_container_image: "mcr.microsoft.com/powershell:lts-nanoserver-ltsc2022"
  primary_windows_image: "${PRIMARY_WINDOWS_IMAGE}"
  windows.ps1: |
    while(\$true) {
      Write-Host "Windows container is running..."
      Start-Sleep -Seconds 30
    }
EOF

  echo "ConfigMap created successfully:"
  oc get configmap winc-test-config -n ${NAMESPACE} -oyaml
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
  namespace: ${NAMESPACE}
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
      imagePullSecrets:
      - name: windows-registry-secret
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

# Function to create Linux workloads
create_linux_workloads() {
  log_message "Creating Linux workloads..."
  create_or_switch_to_namespace

  cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: linux-webserver
  namespace: ${NAMESPACE}
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
      containers:
      - name: linux-webserver
        image: ${LINUX_CONTAINER_IMAGE}
        ports:
        - containerPort: 8080
EOF

  # Wait for Linux workload to be ready
  loops=0
  max_loops=15
  sleep_seconds=20
  while true; do
    if [ X$(oc get deployment linux-webserver -o=jsonpath={.status.readyReplicas}) == X"1" ]; then
      echo "Linux workload is READY"
      break
    fi
    if [ "$loops" -ge "$max_loops" ]; then
      echo "Timeout: Linux workload is not READY"
      exit 1
    fi
    echo "Linux workload is not READY yet, wait $sleep_seconds seconds"
    ((loops++))
    sleep $sleep_seconds
  done
}

# Main execution flow
log_message "Starting deployment in disconnected environment..."
log_message "Using disconnected registry: ${DISCONNECTED_REGISTRY}"

# 1. Create ConfigMap
create_winc_test_configmap

# 2. Create Windows workloads
create_windows_workloads

# 3. Create Linux workloads
create_linux_workloads

log_message "Deployment completed successfully."
oc get nodes -l kubernetes.io/os=windows -owide
