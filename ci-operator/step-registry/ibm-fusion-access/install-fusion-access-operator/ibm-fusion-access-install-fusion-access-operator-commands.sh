#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Installing IBM Fusion Access Operator...'

fusionAccessNamespace="${FA__NAMESPACE:-ibm-fusion-access}"
catalogSourceImage="${FA__CATALOG_SOURCE_IMAGE:-quay.io/openshift-storage-scale/openshift-fusion-access-catalog:stable}"
operatorChannel="${FA__OPERATOR_CHANNEL:-alpha}"

: "Namespace: ${fusionAccessNamespace}"
: "Catalog Source Image: ${catalogSourceImage}"
: "Operator Channel: ${operatorChannel}"

if oc get namespace "${fusionAccessNamespace}" >/dev/null; then
  : "Namespace ${fusionAccessNamespace} already exists"
else
  : "Creating namespace ${fusionAccessNamespace}..."
  oc create namespace "${fusionAccessNamespace}"
fi

oc wait --for=jsonpath='{.status.phase}'=Active namespace/${fusionAccessNamespace} --timeout=60s

: 'Creating OperatorGroup...'
oc apply -f=- <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: storage-scale-operator-group
  namespace: ${fusionAccessNamespace}
spec:
  upgradeStrategy: Default
EOF

oc wait --for=jsonpath='{.metadata.name}'=storage-scale-operator-group operatorgroup/storage-scale-operator-group -n ${fusionAccessNamespace} --timeout=300s

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
  image: "${catalogSourceImage}"
EOF

oc wait --for=jsonpath='{.metadata.name}'=test-fusion-access-operator catalogsource/test-fusion-access-operator -n openshift-marketplace --timeout=300s

: 'Creating Subscription...'
oc apply -f=- <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-fusion-access-operator
  namespace: ${fusionAccessNamespace}
spec:
  channel: ${operatorChannel}
  installPlanApproval: Automatic
  name: openshift-fusion-access-operator
  source: test-fusion-access-operator
  sourceNamespace: openshift-marketplace
EOF

: 'Waiting for Subscription...'
oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/openshift-fusion-access-operator -n ${fusionAccessNamespace} --timeout=600s

: 'Waiting for ClusterServiceVersion...'
csvName=$(oc get subscription openshift-fusion-access-operator -n ${fusionAccessNamespace} -o jsonpath='{.status.installedCSV}')
if [[ -n "${csvName}" ]]; then
  : "Waiting for CSV ${csvName}..."
  oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/${csvName} -n ${fusionAccessNamespace} --timeout=600s
else
  : 'CSV name not found in subscription status, waiting for any CSV...'
  oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -l operators.coreos.com/openshift-fusion-access-operator.${fusionAccessNamespace} -n ${fusionAccessNamespace} --timeout=600s
fi

: 'IBM Fusion Access Operator installation completed'

true
