#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

function create_winc_test_configmap()
{
  oc create configmap winc-test-config -n winc-test --from-literal=primary_windows_image="${1}" --from-literal=primary_windows_container_image="${2}"

  # Display pods and configmap
  oc get pod -owide -n winc-test
  oc get cm winc-test-config -oyaml -n winc-test
}

function setup_image_mirroring()
{
  # Create ImageTagMirrorSet to redirect Windows container images to CI registry
  # Images are pre-mirrored via core-services/image-mirroring/_config.yaml
  # This works for both connected Prow (registry.ci.openshift.org) and disconnected (ephemeral mirror)

  echo "Setting up ImageTagMirrorSet for Windows container images..."

  # Determine mirror registry based on environment
  if [ -f "${SHARED_DIR}/mirror_registry_url" ]; then
    # Disconnected environment with ephemeral mirror registry
    MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
    echo "Disconnected mode: Using ephemeral mirror registry at ${MIRROR_REGISTRY_HOST}"
  else
    # Connected Prow CI - use pre-mirrored images from CI registry
    MIRROR_REGISTRY_HOST="registry.ci.openshift.org"
    echo "Connected mode: Using pre-mirrored images from ${MIRROR_REGISTRY_HOST}"
  fi

  # Create ImageTagMirrorSet to redirect Windows images to mirror
  # Includes PowerShell containers and CSI driver images for storage tests
  # PowerShell: Server 2019 (1809), Server 2022 (ltsc2022)
  # CSI: Azure File and vSphere drivers for OCP-66352
  # TODO: Remove Server 2019 support after AMI/image upgrades to Server 2022
  cat <<EOF | oc create -f -
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: winc-test-tagmirrorset
spec:
  imageTagMirrors:
  - source: mcr.microsoft.com/powershell
    mirrors:
    - ${MIRROR_REGISTRY_HOST}/microsoft/powershell
  - source: mcr.microsoft.com/oss/kubernetes-csi/csi-node-driver-registrar
    mirrors:
    - ${MIRROR_REGISTRY_HOST}/microsoft/csi-node-driver-registrar
  - source: mcr.microsoft.com/k8s/csi/azurefile-csi
    mirrors:
    - ${MIRROR_REGISTRY_HOST}/microsoft/azurefile-csi
  - source: registry.k8s.io/sig-storage/csi-node-driver-registrar
    mirrors:
    - ${MIRROR_REGISTRY_HOST}/k8s/csi-node-driver-registrar
  - source: registry.k8s.io/csi-vsphere/driver
    mirrors:
    - ${MIRROR_REGISTRY_HOST}/k8s/vsphere-csi-driver
  - source: registry.k8s.io/sig-storage/livenessprobe
    mirrors:
    - ${MIRROR_REGISTRY_HOST}/k8s/livenessprobe
EOF

  echo "ImageTagMirrorSet created successfully"
  oc get imagetagmirrorset winc-test-tagmirrorset -o yaml
}

function create_workloads()
{
  oc new-project winc-test
  # turn off the automatic label synchronization required for PodSecurity admission
  # set pods security profile to privileged. See https://kubernetes.io/docs/concepts/security/pod-security-admission/#pod-security-levels
  oc label namespace winc-test security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged  --overwrite

  # Create Windows workload
  oc create -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: win-webserver
  labels:
    app: win-webserver
spec:
  ports:
  # the port that this service should serve on
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
          operator: Equal
          effect: "NoSchedule"
        - key: "os"
          value: "windows"
          operator: Equal
          effect: "NoSchedule"
        - key: "node.cloudprovider.kubernetes.io/uninitialized"
          value: "true"
          operator: Equal
          effect: "NoSchedule"
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

  # Wait up to 5 minutes for Windows workload to be ready
  if ! oc wait deployment win-webserver -n winc-test --for condition=Available=True --timeout=5m; then
    echo "ERROR: Windows workload deployment timed out after 5 minutes"
    echo "=== Debug: Deployment status ==="
    oc get deployment win-webserver -n winc-test -o yaml || true
    echo "=== Debug: All pods status ==="
    oc get pods -n winc-test -l app=win-webserver -o wide || true
    echo "=== Debug: First pod description (sample) ==="
    FIRST_POD=$(oc get pods -n winc-test -l app=win-webserver --no-headers -o custom-columns=":metadata.name" | head -1)
    if [[ -n "${FIRST_POD}" ]]; then
      oc describe pod "${FIRST_POD}" -n winc-test || true
    else
      echo "No pods found"
    fi
    echo "=== Debug: Namespace events ==="
    oc get events -n winc-test --sort-by='.lastTimestamp' || true
    echo "=== Debug: Windows node status ==="
    oc get nodes -l kubernetes.io/os=windows -o wide || true
    echo "=== Debug: ImageTagMirrorSet status ==="
    oc get imagetagmirrorset winc-test-tagmirrorset -o yaml || true
    exit 1
  fi

  # Verify pods are Running
  echo "=== Verifying Windows pods are Running ==="
  running=$(oc get pods -n winc-test -l app=win-webserver --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  echo "Found ${running} Running pod(s)"
  oc get pods -n winc-test -l app=win-webserver -o wide

  # Create Linux workload
  oc create -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: linux-webserver
  labels:
    app: linux-webserver
spec:
  ports:
  # the port that this service should serve on
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
  # Wait up to 5 minutes for Linux workload to be ready (fast, small image)
  if ! oc wait deployment linux-webserver -n winc-test --for condition=Available=True --timeout=5m; then
    echo "ERROR: Linux workload deployment timed out after 5 minutes"
    echo "=== Debug: Pod status ==="
    oc get pods -n winc-test -l app=linux-webserver -o wide || true
    echo "=== Debug: Pod description ==="
    LINUX_POD=$(oc get pods -n winc-test -l app=linux-webserver --no-headers -o custom-columns=":metadata.name" | head -1)
    if [[ -n "${LINUX_POD}" ]]; then
      oc describe pod "${LINUX_POD}" -n winc-test || true
    else
      echo "No pods found"
    fi
    exit 1
  fi
}

echo "=== BYOH Windows Test Environment Setup ==="

# Windows nodes are already provisioned and Ready (verified by windows-byoh-provision step)
# No need to wait for MachineSets - they don't exist for BYOH/UPI

# Get Windows OS image ID from SHARED_DIR (saved by provision step)
# For AWS UPI: aws-windows-ami-discover saves AMI ID
# For other platforms: use descriptive placeholder
if [[ -f "${SHARED_DIR}/AWS_WINDOWS_AMI" ]]; then
    windows_os_image_id=$(cat "${SHARED_DIR}/AWS_WINDOWS_AMI")
    echo "Using Windows AMI from SHARED_DIR: ${windows_os_image_id}"
else
    # Fallback: get from node labels or use placeholder
    windows_os_image_id="byoh-windows-$(oc get nodes -l 'kubernetes.io/os=windows' -o=jsonpath="{.items[0].status.nodeInfo.osImage}" | grep -oP '\d{4}' || echo '2022')"
    echo "Using Windows OS image placeholder: ${windows_os_image_id}"
fi

# Choose the Windows container version depending on the Windows version
# installed on the Windows workers
os_version=$(oc get nodes -l 'kubernetes.io/os=windows' -o=jsonpath="{.items[0].status.nodeInfo.osImage}")

windows_container_image="mcr.microsoft.com/powershell:lts-nanoserver-ltsc2022"
if [[ "$os_version" == *"2019"* ]]
then
    windows_container_image="mcr.microsoft.com/powershell:lts-nanoserver-1809"
fi

echo "Windows OS version: ${os_version}"
echo "Windows OS image ID: ${windows_os_image_id}"
echo "Windows container image: ${windows_container_image}"

# Setup image mirroring for Prow CI (redirects to CI registry)
# This creates ImageTagMirrorSet to redirect Windows image pulls to fast local mirror
setup_image_mirroring


# Wait for Windows nodes to become schedulable (WMCO post-configuration)
# Nodes may be Ready but marked unschedulable during WMCO configuration
echo "Waiting for Windows nodes to become schedulable..."
timeout 5m bash -c '
  while true; do
    # Check if any Windows nodes are unschedulable
    unschedulable=$(oc get nodes -l kubernetes.io/os=windows -o jsonpath="{.items[?(@.spec.unschedulable==true)].metadata.name}")
    if [[ -z "${unschedulable}" ]]; then
      echo "All Windows nodes are schedulable"
      break
    fi
    echo "Waiting for nodes to become schedulable: ${unschedulable}"
    sleep 10
  done
'

# Display Windows node taints before creating workloads
echo "=== Windows node taints ==="
oc get nodes -l kubernetes.io/os=windows -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.taints}{"\n"}{end}'

# Create workloads using the original image (ITMS will redirect to mirror)
# If deployment fails, debug output will show pod/event details
create_workloads "$windows_container_image"

# Create ConfigMap with the original image (ITMS will redirect to mirror)
create_winc_test_configmap "$windows_os_image_id" "$windows_container_image"

echo "=== BYOH Windows Test Environment Ready ==="
