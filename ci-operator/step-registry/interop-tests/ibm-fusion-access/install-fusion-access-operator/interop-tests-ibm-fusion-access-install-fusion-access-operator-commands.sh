#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: '🔧 Installing Fusion Access Operator...'

FA__NAMESPACE="${FA__NAMESPACE:-ibm-fusion-access}"
FA__CATALOG_SOURCE_IMAGE="${FA__CATALOG_SOURCE_IMAGE:-quay.io/openshift-storage-scale/openshift-fusion-access-catalog:stable}"
FA__OPERATOR_CHANNEL="${FA__OPERATOR_CHANNEL:-alpha}"

: "Namespace: ${FA__NAMESPACE}"
: "Catalog Source Image: ${FA__CATALOG_SOURCE_IMAGE}"
: "Operator Channel: ${FA__OPERATOR_CHANNEL}"

oc create namespace "${FA__NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
oc wait --for=jsonpath='{.status.phase}'=Active namespace/"${FA__NAMESPACE}" --timeout=60s

: 'Creating OperatorGroup...'
oc apply -f=- <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: storage-scale-operator-group
  namespace: ${FA__NAMESPACE}
spec:
  upgradeStrategy: Default
EOF

: 'Waiting for OperatorGroup to be ready...'
oc wait --for=jsonpath='{.metadata.name}'=storage-scale-operator-group operatorgroup/storage-scale-operator-group -n ${FA__NAMESPACE} --timeout=300s

: 'Creating CatalogSource...'
oc apply -f=- <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: test-fusion-access-operator
  namespace: openshift-marketplace
spec:
  displayName: Test Storage Scale Operator
  sourceType: grpc
  image: "${FA__CATALOG_SOURCE_IMAGE}"
EOF

: 'Waiting for CatalogSource to be ready...'
oc wait --for=jsonpath='{.metadata.name}'=test-fusion-access-operator catalogsource/test-fusion-access-operator -n openshift-marketplace --timeout=300s

: 'Creating Subscription...'
oc apply -f=- <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-fusion-access-operator
  namespace: ${FA__NAMESPACE}
spec:
  channel: ${FA__OPERATOR_CHANNEL}
  installPlanApproval: Automatic
  name: openshift-fusion-access-operator
  source: test-fusion-access-operator
  sourceNamespace: openshift-marketplace
EOF

: 'Waiting for Subscription to be ready...'
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/openshift-fusion-access-operator -n ${FA__NAMESPACE} --timeout=600s

: 'Waiting for ClusterServiceVersion to be installed and ready...'
csvName=$(oc get subscription openshift-fusion-access-operator -n ${FA__NAMESPACE} -o jsonpath='{.status.installedCSV}')
if [[ -n "${csvName}" ]]; then
  : "Waiting for CSV ${csvName} to be ready..."
  oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/${csvName} -n ${FA__NAMESPACE} --timeout=600s
else
  : '⚠️  CSV name not found in subscription status, waiting for any CSV to be ready...'
  oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -l operators.coreos.com/openshift-fusion-access-operator.${FA__NAMESPACE} -n ${FA__NAMESPACE} --timeout=600s
fi

: '✅ Fusion Access Operator installation completed!'

