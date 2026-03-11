#!/bin/bash

set -euo pipefail

# Target: guest cluster (Cluster A) - installing LVM for KubeVirt VM storage
if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "ERROR: Cluster A kubeconfig not found at ${SHARED_DIR}/kubeconfig"
  exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1-2)
echo "Detected OpenShift version on Cluster A: ${CLUSTER_VERSION}"

LVM_INDEX_IMAGE="quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-catalog:v${CLUSTER_VERSION}"
echo "LVM index image: ${LVM_INDEX_IMAGE}"

CATALOG_SOURCE="${LVM_OPERATOR_SUB_SOURCE}"
INSTALL_NAMESPACE="${LVM_OPERATOR_SUB_INSTALL_NAMESPACE}"
DEVICE="/dev/vdb"

# Step 1: Create IDMS for LVM images
echo "Creating ImageDigestMirrorSet for LVM images"
oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: guest-lvm-operator-idms
spec:
  imageDigestMirrors:
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator
    source: registry.redhat.io/lvms4/lvms-rhel9-operator
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvm-operator-bundle
    source: registry.redhat.io/lvms4/lvms-operator-bundle
  - mirrors:
    - quay.io/redhat-user-workloads/logical-volume-manag-tenant/lvms-must-gather
    source: registry.redhat.io/lvms4/lvms-must-gather-rhel9
EOF

# Step 2: Ensure openshift-marketplace namespace exists
oc get ns openshift-marketplace || oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  name: openshift-marketplace
EOF

# Step 3: Create LVM CatalogSource
echo "Creating LVM CatalogSource: ${CATALOG_SOURCE}"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_SOURCE}
  namespace: openshift-marketplace
spec:
  displayName: LVM CatalogSource
  image: ${LVM_INDEX_IMAGE}
  publisher: OpenShift LVM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF

echo "Waiting for CatalogSource to be ready"
for i in $(seq 1 60); do
  status=$(oc -n openshift-marketplace get catalogsource "${CATALOG_SOURCE}" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
  if [[ "$status" == "READY" ]]; then
    echo "CatalogSource ${CATALOG_SOURCE} is ready"
    break
  fi
  echo "Attempt ${i}/60: CatalogSource status: ${status:-not available}"
  sleep 10
done
if [[ "$status" != "READY" ]]; then
  echo "ERROR: CatalogSource ${CATALOG_SOURCE} failed to become ready"
  oc -n openshift-marketplace get catalogsource "${CATALOG_SOURCE}" -o yaml
  exit 1
fi

# Step 4: Create namespace and subscribe to LVM operator
echo "Creating namespace ${INSTALL_NAMESPACE}"
oc create ns "${INSTALL_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

echo "Creating OperatorGroup"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: lvm-operator-group
  namespace: ${INSTALL_NAMESPACE}
spec:
  targetNamespaces:
  - ${INSTALL_NAMESPACE}
EOF

echo "Creating Subscription for LVM operator"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: ${INSTALL_NAMESPACE}
spec:
  channel: stable
  installPlanApproval: Automatic
  name: lvms-operator
  source: ${CATALOG_SOURCE}
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for LVM operator to be ready"
for i in $(seq 1 60); do
  csv=$(oc -n "${INSTALL_NAMESPACE}" get subscription lvms-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  if [[ -n "$csv" ]]; then
    phase=$(oc -n "${INSTALL_NAMESPACE}" get csv "$csv" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$phase" == "Succeeded" ]]; then
      echo "LVM operator CSV ${csv} is ready"
      break
    fi
  fi
  echo "Attempt ${i}/60: Waiting for LVM operator CSV to succeed..."
  sleep 10
done

# Step 5: Create LVMCluster on /dev/vdb
echo "Creating LVMCluster using device ${DEVICE}"
oc apply -f - <<EOF
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: my-lvmcluster
  namespace: ${INSTALL_NAMESPACE}
spec:
  storage:
    deviceClasses:
    - default: true
      deviceSelector:
        paths:
        - ${DEVICE}
      fstype: xfs
      name: vg1
      thinPoolConfig:
        name: thin-pool-1
        overprovisionRatio: 10
        sizePercent: 90
EOF

echo "Waiting for LVMCluster pods to be running"
for i in $(seq 1 60); do
  not_running=$(oc get pod -n "${INSTALL_NAMESPACE}" --no-headers 2>/dev/null | awk '/(topolvm-node-|vg-manager-)/' | awk '$3 != "Running" {print}' || true)
  if [[ -z "$not_running" ]] && [[ $(oc get pod -n "${INSTALL_NAMESPACE}" --no-headers 2>/dev/null | awk '/(topolvm-node-|vg-manager-)/' | wc -l) -gt 0 ]]; then
    echo "All LVM pods are running"
    break
  fi
  echo "Attempt ${i}/60: Waiting for LVM pods..."
  sleep 10
done

# Set lvms-vg1 as default storage class on Cluster A
for sc in $(oc get storageclass -o name); do
  oc annotate "$sc" storageclass.kubernetes.io/is-default-class- 2>/dev/null || true
done
oc annotate sc lvms-vg1 storageclass.kubernetes.io/is-default-class=true --overwrite

echo "=== LVM setup on Cluster A complete ==="
echo "Storage classes:"
oc get sc
