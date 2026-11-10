#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

oc create namespace "${FA__NAMESPACE}" --dry-run=client -o json --save-config | oc apply -f -
oc wait --for=create namespace/"${FA__NAMESPACE}" --timeout=60s

{
  oc create -f - --dry-run=client -o json --save-config |
  jq --arg ns "${FA__NAMESPACE}" '.metadata.namespace = $ns'
} 0<<'YAML' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: storage-scale-operator-group
spec:
  upgradeStrategy: Default
YAML

{
  oc create -f - --dry-run=client -o json --save-config |
  jq --arg image "${FA__CATALOG_SOURCE_IMAGE}" '.spec.image = $image'
} 0<<'YAML' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: test-fusion-access-operator
  namespace: openshift-marketplace
spec:
  displayName: Test Storage Scale Operator
  sourceType: grpc
YAML

{
  oc create -f - --dry-run=client -o json --save-config |
  jq \
    --arg ns "${FA__NAMESPACE}" \
    --arg channel "${FA__OPERATOR_CHANNEL}" \
    '.metadata.namespace = $ns | .spec.channel = $channel'
} 0<<'YAML' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-fusion-access-operator
spec:
  installPlanApproval: Automatic
  name: openshift-fusion-access-operator
  source: test-fusion-access-operator
  sourceNamespace: openshift-marketplace
YAML

oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/openshift-fusion-access-operator -n "${FA__NAMESPACE}" --timeout=600s

typeset csvName=''
csvName=$(oc get subscription openshift-fusion-access-operator -n "${FA__NAMESPACE}" -o json | jq -r '.status.installedCSV')
[[ "${csvName}" != "null" ]]
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/"${csvName}" -n "${FA__NAMESPACE}" --timeout=600s

{
  oc create -f - --dry-run=client -o json --save-config |
  jq \
    --arg ns "${FA__NAMESPACE}" \
    --arg ver "${FA__STORAGE_SCALE_VERSION}" \
    '.metadata.namespace = $ns | .spec.storageScaleVersion = $ver'
} 0<<'YAML' | oc apply -f -
apiVersion: fusion.storage.openshift.io/v1alpha1
kind: FusionAccess
metadata:
  name: fusionaccess-object
spec:
  storageDeviceDiscovery:
    create: true
YAML

true
