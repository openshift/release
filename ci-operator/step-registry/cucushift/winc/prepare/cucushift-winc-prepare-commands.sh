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

  # Wait up to 5 minutes for Windows workload to be ready
  oc wait deployment win-webserver -n winc-test --for condition=Available=True --timeout=5m

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
  # Wait up to 5 minutes for Linux workload to be ready
  oc wait deployment linux-webserver -n winc-test --for condition=Available=True --timeout=5m
}

IAAS_PLATFORM=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.type}"| tr '[:upper:]' '[:lower:]')


winworker_machineset_name=$(oc get machineset -n openshift-machine-api -o json | jq -r '.items[] | select(.metadata.name | test("win")).metadata.name')
winworker_machineset_replicas=$(oc get machineset -n openshift-machine-api $winworker_machineset_name -o jsonpath="{.spec.replicas}")

echo "Waiting for Windows nodes to come up in Running state"
while [[ $(oc -n openshift-machine-api get machineset/${winworker_machineset_name} -o 'jsonpath={.status.readyReplicas}') != "${winworker_machineset_replicas}" ]]; do echo -n "." && sleep 10; done

# Make sure the Windows nodes get in Ready state
oc wait nodes -l kubernetes.io/os=windows --for condition=Ready=True --timeout=515m

# Choose the Windows container vesion depending on the Windows version
# installed on the Windows workers
os_version=$(oc get nodes -l 'kubernetes.io/os=windows' -o=jsonpath="{.items[0].status.nodeInfo.osImage}")

windows_container_image="mcr.microsoft.com/powershell:lts-nanoserver-ltsc2022"
if [[ "$os_version" == *"2019"* ]]
then
    windows_container_image="mcr.microsoft.com/powershell:lts-nanoserver-1809"
fi

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
	# we need the value after family/
	# in this example projects/windows-cloud/global/images/family/windows-2022-core
	# windows_os_image_id needs to be windows-2022-core
	windows_os_image_id=$(oc get machineset $winworker_machineset_name -o=jsonpath="{.spec.template.spec.providerSpec.value.disks[0].image}" -n openshift-machine-api | tr "/" "\n" | tail -n1)
    ;;
  *)
    echo "Cloud provider \"$IAAS_PLATFORM\" is not supported by WMCO"
    exit 1
    ;;
esac

create_workloads $windows_container_image

create_winc_test_configmap $windows_os_image_id $windows_container_image
