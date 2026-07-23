#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

OO_INSTALL_NAMESPACE=openshift-storage

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
EOF

OPERATORGROUP=$(oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup -o jsonpath="{.items[*].metadata.name}" || true)
if [[ -n "$OPERATORGROUP" ]]; then
    echo "OperatorGroup \"$OPERATORGROUP\" exists: modifying it"
    OG_OPERATION=apply
    OG_NAMESTANZA="name: $OPERATORGROUP"
else
    echo "OperatorGroup does not exist: creating it"
    OG_OPERATION=create
    OG_NAMESTANZA="generateName: oo-"
fi

OPERATORGROUP=$(
    oc $OG_OPERATION -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  $OG_NAMESTANZA
  namespace: $OO_INSTALL_NAMESPACE
spec:
  targetNamespaces: [$OO_INSTALL_NAMESPACE]
EOF
)

SUB=$(
    cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: $OO_INSTALL_NAMESPACE
spec:
  installPlanApproval: Automatic
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
)

for _ in {1..60}; do
    CSV=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n "$OO_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"
            CSV_READY=true
            break
        fi
    fi
    sleep 10
done

if [[ "${CSV_READY:-}" != "true" ]]; then
    echo "Timed out waiting for CSV to become ready"
    exit 1
fi

if [[ "${SETUP_NOOBAA:-false}" != "true" ]]; then
    echo "SETUP_NOOBAA not enabled, skipping NooBaa setup"
    exit 0
fi

echo "Waiting for NooBaa CRD to be available..."
TIMEOUT=300
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    if oc get crd noobaas.noobaa.io > /dev/null 2>&1; then
        echo "NooBaa CRD is available"
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done
if ! oc get crd noobaas.noobaa.io > /dev/null 2>&1; then
    echo "ERROR: NooBaa CRD not available within ${TIMEOUT}s"
    oc get csv -n "$OO_INSTALL_NAMESPACE" 2>&1 || true
    exit 1
fi

echo "Creating NooBaa..."
cat <<EOF | oc apply -f -
apiVersion: noobaa.io/v1alpha1
kind: NooBaa
metadata:
  name: noobaa
  namespace: $OO_INSTALL_NAMESPACE
spec:
  manualDefaultBackingStore: true
  dbResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
  coreResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
  dbType: postgres
EOF

echo "Waiting for NooBaa to become available (up to 900s)..."
if ! oc -n "$OO_INSTALL_NAMESPACE" wait noobaa/noobaa \
    --for=condition=Available --timeout=900s; then
    echo "ERROR: NooBaa not available within 900s"
    oc get noobaa/noobaa -n "$OO_INSTALL_NAMESPACE" -o yaml 2>&1 || true
    oc get pods -n "$OO_INSTALL_NAMESPACE" 2>&1 || true
    exit 1
fi

echo "Creating PV-pool backing store..."
cat <<EOF | oc apply -f -
apiVersion: noobaa.io/v1alpha1
kind: BackingStore
metadata:
  name: noobaa-default-backing-store
  namespace: $OO_INSTALL_NAMESPACE
  finalizers:
  - noobaa.io/finalizer
  labels:
    app: noobaa
spec:
  type: pv-pool
  pvPool:
    numVolumes: 1
    resources:
      requests:
        storage: 50Gi
        cpu: "500m"
        memory: "2Gi"
      limits:
        cpu: "1"
        memory: "4Gi"
EOF

echo "Creating default bucket class..."
cat <<EOF | oc apply -f -
apiVersion: noobaa.io/v1alpha1
kind: BucketClass
metadata:
  name: noobaa-default-bucket-class
  namespace: $OO_INSTALL_NAMESPACE
  labels:
    app: noobaa
spec:
  placementPolicy:
    tiers:
    - backingStores:
      - noobaa-default-backing-store
EOF

echo "Waiting for backing store to be ready..."
for i in $(seq 1 60); do
    BS_PHASE=$(oc -n "$OO_INSTALL_NAMESPACE" get backingstore \
        noobaa-default-backing-store \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    if [ "$BS_PHASE" = "Ready" ]; then
        echo "Default backing store is ready"
        break
    fi
    echo "  [${i}0s] Backing store phase: $BS_PHASE"
    sleep 10
done
if [ "$BS_PHASE" != "Ready" ]; then
    echo "WARNING: Backing store not ready (phase: $BS_PHASE), proceeding anyway"
    oc get backingstore -n "$OO_INSTALL_NAMESPACE" -o yaml 2>&1 || true
fi

echo "NooBaa setup complete"
