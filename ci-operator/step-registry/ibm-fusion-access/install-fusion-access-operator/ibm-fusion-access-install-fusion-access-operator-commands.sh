#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Install the Fusion Access operator from a catalog source, wait for CSV success, apply the FusionAccess CR, and wait for the CR to be visible.
# Inputs: FA__NAMESPACE, FA__CATALOG_SOURCE_IMAGE, FA__OPERATOR_CHANNEL, FA__STORAGE_SCALE_VERSION (step ref env).
# Non-obvious: Subscription and CSV waits precede FusionAccess; FusionAccess wait uses jsonpath on metadata.name.

oc create namespace "${FA__NAMESPACE}" --dry-run=client -o json --save-config | oc apply -f -
if ! oc wait --for=create namespace/"${FA__NAMESPACE}" --timeout=60s; then
  oc get namespace "${FA__NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

{
  oc create -f - --dry-run=client -o json --save-config |
  jq -c --arg ns "${FA__NAMESPACE}" '.metadata.namespace = $ns' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: storage-scale-operator-group
  namespace: placeholder
spec:
  upgradeStrategy: Default
YAML

{
  oc create -f - --dry-run=client -o json --save-config |
  jq -c --arg img "${FA__CATALOG_SOURCE_IMAGE}" '.spec.image = $img' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: test-fusion-access-operator
  namespace: openshift-marketplace
spec:
  displayName: Test Storage Scale Operator
  image: placeholder
  sourceType: grpc
YAML

{
  oc create -f - --dry-run=client -o json --save-config |
  jq -c \
    --arg ns "${FA__NAMESPACE}" \
    --arg ch "${FA__OPERATOR_CHANNEL}" \
    '.metadata.namespace = $ns | .spec.channel = $ch' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-fusion-access-operator
  namespace: placeholder
spec:
  channel: placeholder
  installPlanApproval: Automatic
  name: openshift-fusion-access-operator
  source: test-fusion-access-operator
  sourceNamespace: openshift-marketplace
YAML

if ! oc wait --for=jsonpath='{.status.state}'=AtLatestKnown subscription/openshift-fusion-access-operator -n "${FA__NAMESPACE}" --timeout=600s; then
  oc get subscription openshift-fusion-access-operator -n "${FA__NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

typeset csvName=''
csvName="$(oc get subscription openshift-fusion-access-operator -n "${FA__NAMESPACE}" -o jsonpath='{.status.installedCSV}')"
if [[ -z "${csvName}" ]]; then
  oc get subscription openshift-fusion-access-operator -n "${FA__NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi
if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/"${csvName}" -n "${FA__NAMESPACE}" --timeout=600s; then
  oc get csv "${csvName}" -n "${FA__NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

{
  oc create -f - --dry-run=client -o json --save-config |
  jq -c \
    --arg ns "${FA__NAMESPACE}" \
    --arg ver "${FA__STORAGE_SCALE_VERSION}" \
    '.metadata.namespace = $ns | .spec.storageScaleVersion = $ver' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: fusion.storage.openshift.io/v1alpha1
kind: FusionAccess
metadata:
  name: fusionaccess-object
  namespace: placeholder
spec:
  storageDeviceDiscovery:
    create: true
  storageScaleVersion: placeholder
YAML

if ! oc wait --for=jsonpath='{.metadata.name}'=fusionaccess-object fusionaccess/fusionaccess-object -n "${FA__NAMESPACE}" --timeout=300s; then
  oc get fusionaccess fusionaccess-object -n "${FA__NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

true
