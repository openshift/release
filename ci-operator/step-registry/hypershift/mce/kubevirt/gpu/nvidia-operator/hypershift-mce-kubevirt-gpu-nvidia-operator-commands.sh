#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  exit 1
fi
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

if ! oc get packagemanifest | grep -q "gpu-operator-certified"; then
  VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | awk -F. -v OFS=. '{$2=$2-1; print $1,$2}')
  oc apply -f - <<EOF
kind: CatalogSource
apiVersion: operators.coreos.com/v1alpha1
metadata:
  name: certified-operators-gpu
  namespace: openshift-marketplace
spec:
  displayName: Certified Operators gpu
  image: registry.redhat.io/redhat/certified-operator-index:v${VERSION}
  priority: -100
  publisher: Red Hat
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 10m0s
EOF
fi

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
EOF

channel=$(oc get packagemanifest gpu-operator-certified -ojsonpath='{.status.channels[0].name}')
catalog=$(oc get packagemanifest gpu-operator-certified -ojsonpath='{.status.catalogSource}')
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: gpu-operator-certified
  source: ${catalog}
  sourceNamespace: openshift-marketplace
EOF

CSVName=""
for ((i=1; i<=60; i++)); do
  output=$(oc get sub gpu-operator-certified -n nvidia-gpu-operator -o jsonpath='{.status.currentCSV}' >> /dev/null && echo "exists" || echo "not found")
  if [ "$output" != "exists" ]; then
    sleep 2
    continue
  fi
  CSVName=$(oc get sub gpu-operator-certified -n nvidia-gpu-operator -o jsonpath='{.status.currentCSV}')
  if [ "$CSVName" != "" ]; then
    break
  fi
  sleep 10
done

_apiReady=0
echo "* Using CSV: ${CSVName}"
for ((i=1; i<=20; i++)); do
  sleep 30
  output=$(oc get csv -n nvidia-gpu-operator $CSVName -o jsonpath='{.status.phase}' >> /dev/null && echo "exists" || echo "not found")
  if [ "$output" != "exists" ]; then
    continue
  fi
  phase=$(oc get csv -n nvidia-gpu-operator $CSVName -o jsonpath='{.status.phase}')
  if [ "$phase" == "Succeeded" ]; then
    _apiReady=1
    break
  fi
  echo "Waiting for CSV to be ready"
done

if [ $_apiReady -eq 0 ]; then
  echo "nvidia-gpu-operator subscription could not install in the allotted time."
  exit 1
fi
echo "nvidia-gpu-operator installed successfully"

oc get csv -n nvidia-gpu-operator $CSVName -o jsonpath='{.metadata.annotations.alm-examples}' | jq '.[0]'  > /tmp/clusterpolicy.json
oc apply -f /tmp/clusterpolicy.json

#https://docs.nvidia.com/datacenter/cloud-native/openshift/23.9.2/troubleshooting-gpu-ocp.html#verify-the-nvidia-driver-deployment
oc wait ClusterPolicy --for=condition=Ready --timeout=15m --all

while read -r name _ _ _; do
  gpu_info=$(oc debug node/"${name}" -- chroot /host bash -c 'lspci -nnv' | grep -i nvidia)

  if [[ -z "$gpu_info" ]]; then
    exit 1  # Exit with error if NVIDIA GPU is not found
  fi
done < <(oc get node --no-headers)

oc create namespace cuda-test
IMAGE=$(oc get clusterversion version -ojsonpath='{.status.desired.image}')
TOOLS_IMAGE=$(oc adm release info ${IMAGE} --image-for=tools)
echo "$TOOLS_IMAGE"
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cuda-test-workload
  namespace: cuda-test
spec:
  replicas: 3
  selector:
    matchLabels:
      app: cuda-test-workload
  template:
    metadata:
      labels:
        app: cuda-test-workload
    spec:
      containers:
        - name: cuda-vectoradd
          image: "nvidia/samples:vectoradd-cuda11.2.1"
          resources:
           limits:
              nvidia.com/gpu: 2
EOF
oc wait deployment cuda-test-workload -n cuda-test --for condition=Available=True --timeout=5m