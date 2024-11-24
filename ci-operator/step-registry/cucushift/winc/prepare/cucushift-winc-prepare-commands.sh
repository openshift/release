#!/bin/bash
# Enable strict error handling and debugging
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
    
    # Show pod logs with environment status
    echo "=== Pod Logs (with Environment Status) ==="
    for pod in $(oc get pods -n winc-test -l app=$deployment_name -o name); do
        echo "--- Logs for $pod ---"
        echo "Environment Status Check:"
        oc logs -n winc-test $pod | grep -i "Environment Status"
        echo "Full Logs:"
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
    
    echo "Checking if environment is disconnected..."
    if curl -s --connect-timeout 5 https://registry.redhat.io > /dev/null; then
        echo "Environment is connected, skipping disconnected preparation"
        return 0
    fi
    
    echo "Environment is disconnected, starting preparation..."
    
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
    echo "Checking if cluster is disconnected..."
    
    # Try to access external registry
    if curl -s --connect-timeout 5 https://registry.redhat.io > /dev/null; then
        echo "External registry is accessible - Connected environment detected"
        return 1
    fi
    
    echo "External registry is not accessible - Disconnected environment detected"
    
    local output
    output=$(oc get configmap winc-test-config -n winc-test -o yaml 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "ConfigMap not found - assuming connected environment"
        return 1
    fi

    if echo "$output" | grep -q "<primary_windows_container_disconnected_image>" || \
       echo "$output" | grep -q "<linux_container_disconnected_image>"; then
        echo "Found placeholder values in ConfigMap - assuming connected environment"
        return 1
    fi

    if ! echo "$output" | grep -q "primary_windows_container_disconnected_image:" || \
       ! echo "$output" | grep -q "linux_container_disconnected_image:"; then
        echo "Missing required keys in ConfigMap - assuming connected environment"
        return 1
    fi

    echo "Confirmed disconnected environment"
    return 0
}

# Function to create test configmap
function create_winc_test_configmap() {
    local win_image="$1"
    local win_container_image="$2"
    local linux_container_image="$3"

    echo "=== Creating winc-test configmap ==="
    oc create configmap winc-test-config -n winc-test \
        --from-literal=primary_windows_image="${win_image}" \
        --from-literal=primary_windows_container_image="${win_container_image}" \
        --from-literal=linux_container_disconnected_image="${linux_container_image}" || true

    oc get pod -owide -n winc-test
    oc get cm winc-test-config -oyaml -n winc-test
}

# Function to ensure namespace exists and set security context
function ensure_namespace() {
    if ! oc get namespace winc-test >/dev/null 2>&1; then
        echo "=== Creating winc-test namespace ==="
        oc new-project winc-test
    fi
    
    # Set pod security policy
    oc label namespace winc-test security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged --overwrite
}

# Function to deploy Windows workload
function deploy_windows_workload() {
    local windows_container_image=$1
    
    echo "=== Deploying Windows Workload ==="
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: win-webserver
  namespace: winc-test
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
  name: win-webserver
  namespace: winc-test
  labels: 
    app: win-webserver
spec:
  selector:
    matchLabels:
      app: win-webserver
  replicas: 5
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
      containers:
        - name: win-webserver
          image: ${windows_container_image}
          imagePullPolicy: IfNotPresent
          command:
            - pwsh.exe
            - -command
            - |
              \$isDisconnected = \$false
              try {
                  Write-Host "Checking environment connectivity..."
                  Invoke-WebRequest -Uri 'https://registry.redhat.io' -TimeoutSec 5 -UseBasicParsing | Out-Null
                  Write-Host "Environment Status: Connected"
              } catch {
                  \$isDisconnected = \$true
                  Write-Host "Environment Status: Disconnected"
              }

              Write-Host "Starting web server..."
              \$listener = New-Object System.Net.HttpListener
              \$listener.Prefixes.Add('http://*:80/')
              \$listener.Start()
              Write-Host('Listening at http://*:80/')

              while (\$listener.IsListening) {
                  \$context = \$listener.GetContext()
                  \$response = \$context.Response
                  \$content = '<html><body><H1>Windows Container Web Server</H1>'
                  \$content += '<p>Environment Status: ' + (if (\$isDisconnected) { 'Disconnected' } else { 'Connected' }) + '</p>'
                  \$content += '</body></html>'
                  \$buffer = [System.Text.Encoding]::UTF8.GetBytes(\$content)
                  \$response.ContentLength64 = \$buffer.Length
                  \$response.OutputStream.Write(\$buffer, 0, \$buffer.Length)
                  \$response.Close()
              }
          securityContext:
            runAsNonRoot: false
            windowsOptions:
              runAsUserName: "ContainerAdministrator"
EOF

    echo "Waiting for Windows workload..."
    oc wait deployment win-webserver -n winc-test --for condition=Available=True --timeout=5m || true
    debug_deployment "win-webserver"
}

# Function to deploy Linux workload
function deploy_linux_workload() {
    local linux_container_image=$1
    
    echo "=== Deploying Linux Workload ==="
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: linux-webserver
  namespace: winc-test
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
  name: linux-webserver
  namespace: winc-test
  labels:
    app: linux-webserver
spec:
  selector:
    matchLabels:
      app: linux-webserver
  replicas: 1
  template:
    metadata:
      labels:
        app: linux-webserver
    spec:
      containers:
      - name: linux-webserver
        image: ${linux_container_image}
        imagePullPolicy: IfNotPresent
        command:
          - /bin/sh
          - -c
          - |
            echo "Checking environment connectivity..."
            if curl -s --connect-timeout 5 https://registry.redhat.io > /dev/null; then
              echo "Environment Status: Connected"
              ENV_STATUS="Connected"
            else
              echo "Environment Status: Disconnected"
              ENV_STATUS="Disconnected"
            fi
            
            echo "Starting Python web server..."
            cat > index.html << END
            <html><body>
            <h1>Linux Container Web Server</h1>
            <p>Environment Status: \$ENV_STATUS</p>
            </body></html>
            END
            
            python3 -m http.server 8080
EOF

    echo "Waiting for Linux workload..."
    oc wait deployment linux-webserver -n winc-test --for condition=Available=True --timeout=5m || true
    debug_deployment "linux-webserver"
}

# Main script execution starts here

# Get infrastructure platform type
IAAS_PLATFORM=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.type}"| tr '[:upper:]' '[:lower:]')

# Get Windows machineset info
winworker_machineset_name=$(oc get machineset -n openshift-machine-api -o json | jq -r '.items[] | select(.metadata.name | test("win")).metadata.name')
winworker_machineset_replicas=$(oc get machineset -n openshift-machine-api $winworker_machineset_name -o jsonpath="{.spec.replicas}")

# Set container images based on environment
if isDisconnectedCluster; then
    DISCONNECTED_IMAGE_REGISTRY=$(oc get configmap winc-test-config -n winc-test -o jsonpath='{.data.primary_windows_container_disconnected_image}' | awk -F/ '{print $1}')
    windows_container_image="${DISCONNECTED_IMAGE_REGISTRY}/powershell:lts-nanoserver-ltsc2022"
    linux_container_image=$(oc get configmap winc-test-config -n winc-test -o jsonpath='{.data.linux_container_disconnected_image}')
    disconnected_prepare "${DISCONNECTED_IMAGE_REGISTRY}"
else
    windows_container_image="mcr.microsoft.com/powershell:lts-nanoserver-ltsc2022"
    linux_container_image="quay.io/openshifttest/hello-openshift:multiarch-winc"
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

# 1. First ensure namespace exists
ensure_namespace

# 2. Create configmap first with image information
create_winc_test_configmap "$windows_os_image_id" "$windows_container_image" "$linux_container_image"

# 3. Then deploy workloads
deploy_linux_workload "$linux_container_image"
deploy_windows_workload "$windows_container_image"

# Show final cluster status
echo "=== Node Status ==="
oc get nodes -o wide

echo "=== Namespace Security Context ==="
oc get namespace winc-test -o yaml

echo "=== Network Policies ==="
oc get networkpolicy -n winc-test

echo "=== Storage Class & PV Status ==="
oc get sc,pv,pvc -n winc-test
