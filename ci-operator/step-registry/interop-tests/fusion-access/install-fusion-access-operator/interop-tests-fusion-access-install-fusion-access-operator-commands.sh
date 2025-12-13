#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "🔧 Installing Fusion Access Operator..."

FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"
CATALOG_SOURCE_IMAGE="${CATALOG_SOURCE_IMAGE:-quay.io/openshift-storage-scale/openshift-fusion-access-catalog:stable}"
OPERATOR_CHANNEL="${OPERATOR_CHANNEL:-alpha}"

echo "Namespace: ${FUSION_ACCESS_NAMESPACE}"
echo "Catalog Source Image: ${CATALOG_SOURCE_IMAGE}"
echo "Operator Channel: ${OPERATOR_CHANNEL}"

if oc get namespace "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "✅ Namespace ${FUSION_ACCESS_NAMESPACE} already exists"
else
  echo "Creating namespace ${FUSION_ACCESS_NAMESPACE}..."
  oc create namespace "${FUSION_ACCESS_NAMESPACE}"
fi

echo "Waiting for namespace to be ready..."
oc wait --for=jsonpath='{.status.phase}'=Active namespace/${FUSION_ACCESS_NAMESPACE} --timeout=60s

echo "Creating OperatorGroup..."
oc apply -f=- <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: storage-scale-operator-group
  namespace: ${FUSION_ACCESS_NAMESPACE}
spec:
  upgradeStrategy: Default
EOF

echo "Waiting for OperatorGroup to be ready..."
oc wait --for=jsonpath='{.metadata.name}'=storage-scale-operator-group operatorgroup/storage-scale-operator-group -n ${FUSION_ACCESS_NAMESPACE} --timeout=300s

echo "Creating CatalogSource..."
oc apply -f=- <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: test-fusion-access-operator
  namespace: openshift-marketplace
spec:
  displayName: Test Storage Scale Operator
  sourceType: grpc
  image: "${CATALOG_SOURCE_IMAGE}"
EOF

echo "Waiting for CatalogSource to be ready..."
oc wait --for=jsonpath='{.metadata.name}'=test-fusion-access-operator catalogsource/test-fusion-access-operator -n openshift-marketplace --timeout=300s

echo "Creating Subscription..."
oc apply -f=- <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-fusion-access-operator
  namespace: ${FUSION_ACCESS_NAMESPACE}
spec:
  channel: ${OPERATOR_CHANNEL}
  installPlanApproval: Automatic
  name: openshift-fusion-access-operator
  source: test-fusion-access-operator
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for Subscription to be ready..."
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/openshift-fusion-access-operator -n ${FUSION_ACCESS_NAMESPACE} --timeout=600s

echo "Waiting for ClusterServiceVersion to be installed and ready..."
CSV_NAME=$(oc get subscription openshift-fusion-access-operator -n ${FUSION_ACCESS_NAMESPACE} -o jsonpath='{.status.installedCSV}')
if [[ -n "${CSV_NAME}" ]]; then
  echo "Waiting for CSV ${CSV_NAME} to be ready..."
  oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/${CSV_NAME} -n ${FUSION_ACCESS_NAMESPACE} --timeout=600s
else
  echo "⚠️  CSV name not found in subscription status, waiting for any CSV to be ready..."
  oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -l operators.coreos.com/openshift-fusion-access-operator.${FUSION_ACCESS_NAMESPACE} -n ${FUSION_ACCESS_NAMESPACE} --timeout=600s
fi

echo "✅ Fusion Access Operator installation completed!"
