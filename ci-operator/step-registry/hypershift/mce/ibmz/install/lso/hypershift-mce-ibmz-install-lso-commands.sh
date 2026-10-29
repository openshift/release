#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

timeout=300       # seconds
interval=10       # seconds
elapsed=0

echo "⏳ Waiting for Local Storage Operator packagemanifest to appear..."

while true; do
    if oc get packagemanifests -n openshift-marketplace 2>/dev/null \
        | grep -i "local-storage"; then
        echo "Local Storage Operator packagemanifest found!"
        break
    fi

    if [[ $elapsed -ge $timeout ]]; then
        echo "Timed out waiting for Local Storage Operator packagemanifest."
        exit 1
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
done

LOCAL_STORAGE_OPERATOR_SUB_SOURCE=$(
cat <<EOF | awk '/name:/ {print $2; exit}'
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhat-operators-stage
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  publisher: redhat
  displayName: Red Hat Operators v4.19 Stage
  image: quay.io/openshift-release-dev/ocp-release-nightly:iib-int-index-art-operators-4.19
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
)

echo "$LOCAL_STORAGE_OPERATOR_SUB_SOURCE"

# Install the LSO operator
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-local-storage
spec: {}
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: local-operator-group
  namespace: openshift-local-storage
spec:
  targetNamespaces:
  - openshift-local-storage
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: local-storage-operator
  namespace: openshift-local-storage
spec:
  channel: stable
  installPlanApproval: Automatic
  name: local-storage-operator
  source: "${LOCAL_STORAGE_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

# Wait for the LSO CSV to appear
until oc get csv -n openshift-local-storage | grep -i local-storage-operator; do
  echo "Waiting for LSO operator"
  sleep 5
done

# Extract ONLY the correct CSV
CSV=$(oc get csv -n openshift-local-storage -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | grep local-storage-operator \
    | head -n1)

echo "Found LSO CSV: $CSV"

# Wait for the CSV to succeed
oc wait --for=jsonpath='{.status.phase}'=Succeeded \
    --timeout=10m \
    -n openshift-local-storage \
    csv/${CSV}

# Create LocalVolumeDiscovery
oc apply -f - <<EOF
kind: LocalVolumeDiscovery
apiVersion: local.storage.openshift.io/v1alpha1
metadata:
  name: auto-discover-devices
  namespace: openshift-local-storage
spec:
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
          - key: node-role.kubernetes.io/worker
            operator: Exists
EOF

# Create LocalVolume
oc apply -f - <<EOF
kind: LocalVolume
apiVersion: local.storage.openshift.io/v1
metadata:
  name: local-block-ocs
  namespace: openshift-local-storage
spec:
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
          - key: cluster.ocs.openshift.io/openshift-storage
            operator: Exists
  storageClassDevices:
    - storageClassName: local-block-ocs
      volumeMode: Block
      devicePaths: ["/dev/vdd"]
EOF

# Node labeling
for i in $(oc get node -l node-role.kubernetes.io/worker -oname | grep -oP "^node/\K.*"); do
  oc label node $i cluster.ocs.openshift.io/openshift-storage='' --overwrite
done

# Validation
if oc get pods -n openshift-local-storage 2>/dev/null | grep -E "Running" >/dev/null; then
    echo "Successfully installed local-storage-operator."
else
    echo "Local-storage-operator installation failed."
    exit 1
fi