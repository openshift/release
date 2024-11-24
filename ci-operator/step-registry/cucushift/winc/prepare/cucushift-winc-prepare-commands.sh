#!bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Function to debug deployment status and logs
function debug_deployment() {
    local deployment_name=$1
    echo "=== Debug info for $deployment_name ==="
    
    # Check pod status
    echo "=== Pod Status ==="
    oc get pods -n winc-test -l app=$deployment_name -o wide
    
    # Show pod details
    echo "=== Pod Description ==="
    oc describe pods -n winc-test -l app=$deployment_name
    
    # Show deployment status
    echo "=== Deployment Status ==="
    oc describe deployment $deployment_name -n winc-test
    
    # Show pod logs
    echo "=== Pod Logs ==="
    for pod in $(oc get pods -n winc-test -l app=$deployment_name -o name); do
        echo "--- Logs for $pod ---"
        oc logs -n winc-test $pod
    done
    
    # Show related events
    echo "=== Recent Events ==="
    oc get events -n winc-test --sort-by='.lastTimestamp' | grep $deployment_name
}

# Function to handle disconnected environment setup
function disconnected_prepare() {
    # Extract registry hostname from image
    DISCONNECTED_REGISTRY=$(echo $1 | awk -F/ '{print $1}')
    export DISCONNECTED_REGISTRY
    
    # Add the registry certificate to trust
    echo "=== Adding registry certificate to trust ==="
    oc -n openshift-config get cm custom-ca -o yaml
    
    if [ -n "${DISCONNECTED_REGISTRY}" ]; then
        echo "Setting up disconnected registry: ${DISCONNECTED_REGISTRY}"
        oc extract -n openshift-config secret/pull-secret --to=.
        jq -r '.auths += {"'"${DISCONNECTED_REGISTRY}"'": {"auth": "'"$(echo -n "key:value" | base64 -w0)"'","email": "test@test.com"}}' .dockerconfigjson > ./pull-secret
        oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=./pull-secret
        rm -f ./.dockerconfigjson ./pull-secret
    fi
}

# Function to check if cluster is disconnected
function isDisconnectedCluster() {
    local output
    # Get configmap content
    output=$(oc get configmap winc-test-config -n winc-test -o yaml 2>/dev/null)
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Check if values are placeholders
    if echo "$output" | grep -q "<primary_windows_container_disconnected_image>" || \
       echo "$output" | grep -q "<linux_container_disconnected_image>"; then
        return 1
    fi

    # Check if required keys exist
    if ! echo "$output" | grep -q "primary_windows_container_disconnected_image:" || \
       ! echo "$output" | grep -q "linux_container_disconnected_image:"; then
        return 1
    fi

    return 0
}

# Function to create test configmap
function create_winc_test_configmap() {
    oc create configmap winc-test-config -n winc-test \
        --from-literal=primary_windows_image="${1}" \
        --from-literal=primary_windows_container_image="${2}"

    # Display pods and configmap
    oc get pod -owide -n winc-test
    oc get cm winc-test-config -oyaml -n winc-test
}

# Function to create Windows and Linux workloads
function create_workloads() {
    oc new-project winc-test
    
    # Configure Pod Security Admission
    oc label namespace winc-test security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged --overwrite

    # Create Windows workload
    echo "=== Creating Windows Workload ==="
    oc create -f - <<EOF
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
  replicas: 5
  template:
    metadata:
      labels:
        app: win-webserver
      name: win-webserver
    spec:
      nodeSelector:
        kubernetes.io/os: windows
      tolerations:
        - key: "os"
          value: "Windows"
          Effect: "NoSchedule"
      containers:
        - name: win-webserver
          image: ${1}
          imagePullPolicy: IfNotPresent
          command:
            - pwsh.exe
            - -command
            - \$listener = New-Object System.Net.HttpListener; \$listener.Prefixes.Add('http://*:80/'); \$listener.Start();Write-Host('Listening at http://*:80/'); while (\$listener.IsListening) { \$context = \$listener.GetContext(); \$response = \$context.Response; \$content='<html><body><H1>Windows Container Web Server</H1></body></html>'; \$buffer = [System.Text.Encoding]::UTF8.GetBytes(\$content); \$response.ContentLength64 = \$buffer.Length; \$response.OutputStream.Write(\$buffer, 0, \$buffer.Length); \$response.Close(); };
          securityContext:
            runAsNonRoot: false
            windowsOptions:
              runAsUserName: "ContainerAdministrator"
EOF

    # Wait for Windows workload
    oc wait deployment win-webserver -n winc-test --for condition=Available=True --timeout=5m
    debug_deployment "win-webserver"

    # Create Linux workload
    echo "=== Creating Linux Workload ==="
    oc create -f - <<EOF
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
        image: quay.io/openshifttest/hello-openshift:multiarch-winc
        ports:
        - containerPort: 8080
EOF

    # Wait for Linux workload
    oc wait deployment linux-webserver -n winc-test --for condition=Available=True --timeout=5m
    debug_deployment "linux-webserver"

    # Show additional cluster information
    echo "=== Node Status ==="
    oc get nodes -o wide
    
    echo "=== Namespace Security Context ==="
    oc get namespace winc-test -o yaml
    
    echo "=== Network Policies ==="
    oc get networkpolicy -n winc-test
    
    echo "=== Storage Class & PV Status ==="
    oc get sc,pv,pvc -n winc-test
}

# Get the infrastructure platform type
IAAS_PLATFORM=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.type}"| tr '[:upper:]' '[:lower:]')

# Get Windows machineset information
winworker_machineset_name=$(oc get machineset -n openshift-machine-api -o json | jq -r '.items[] | select(.metadata.name | test("win")).metadata.name')
winworker_machineset_replicas=$(oc get machineset -n openshift-machine-api $winworker_machineset_name -o jsonpath="{.spec.replicas}")

# Wait for Windows nodes
echo "Waiting for Windows nodes to come up in Running state"
while [[ $(oc -n openshift-machine-api get machineset/${winworker_machineset_name} -o 'jsonpath={.status.readyReplicas}') != "${winworker_machineset_replicas}" ]]; do 
    echo -n "." && sleep 10
done

# Wait for Windows nodes to be ready
oc wait nodes -l kubernetes.io/os=windows --for condition=Ready=True --timeout=15m

# Setup container image paths based on environment
if isDisconnectedCluster; then
    DISCONNECTED_IMAGE_REGISTRY=$(oc get configmap winc-test-config -n winc-test -o jsonpath='{.data.primary_windows_container_disconnected_image}' | awk -F/ '{print $1}')
    windows_container_image="${DISCONNECTED_IMAGE_REGISTRY}/powershell:lts-nanoserver-ltsc2022"
    disconnected_prepare "${DISCONNECTED_IMAGE_REGISTRY}"
else
    windows_container_image="mcr.microsoft.com/powershell:lts-nanoserver-ltsc2022"
fi

# Get Windows OS image ID based on platform
case "$IAAS_PLATFORM" in
    aws)
        windows_os_image_id=$(oc get machineset $winworker_machineset_name -o=jsonpath="{.spec.template.spec.providerSpec.value.ami.id}" -n openshift-machine-api)
        ;;
    azure)
        windows_os_image_id=$(oc get machineset $winworker_machineset_name -o=jsonpath="{.spec.template.spec.providerSpec.value.image.sku}" -n openshift-machine-api)
        ;;
    vsphere)
        windows_os_image_id=$(oc get machineset $winworker_machineset_name -o=jsonpath="{.spec.template.spec.providerSpec.value.template}" -n openshift-machine-api)
        ;;
    gcp)
        windows_os_image_id=$(oc get machineset $winworker_machineset_name -o=jsonpath="{.spec.template.spec.providerSpec.value.disks[0].image}" -n openshift-machine-api | tr "/" "\n" | tail -n1)
        ;;
    *)
        echo "Cloud provider \"$IAAS_PLATFORM\" is not supported by WMCO"
        exit 1
        ;;
esac

# Create workloads and configmap
create_workloads $windows_container_image
create_winc_test_configmap $windows_os_image_id $windows_container_image
