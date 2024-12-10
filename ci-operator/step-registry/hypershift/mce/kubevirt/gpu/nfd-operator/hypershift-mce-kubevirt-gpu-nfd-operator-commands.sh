#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  exit 1
fi
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nfd-group
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
EOF

channel=$(oc get packagemanifest nfd -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

CSVName=""
for ((i=1; i<=60; i++)); do
  output=$(oc get sub nfd -n openshift-nfd -o jsonpath='{.status.currentCSV}' >> /dev/null && echo "exists" || echo "not found")
  if [ "$output" != "exists" ]; then
    sleep 2
    continue
  fi
  CSVName=$(oc get sub nfd -n openshift-nfd -o jsonpath='{.status.currentCSV}')
  if [ "$CSVName" != "" ]; then
    break
  fi
  sleep 10
done

_apiReady=0
echo "* Using CSV: ${CSVName}"
for ((i=1; i<=20; i++)); do
  sleep 30
  output=$(oc get csv -n openshift-nfd $CSVName -o jsonpath='{.status.phase}' >> /dev/null && echo "exists" || echo "not found")
  if [ "$output" != "exists" ]; then
    continue
  fi
  phase=$(oc get csv -n openshift-nfd $CSVName -o jsonpath='{.status.phase}')
  if [ "$phase" == "Succeeded" ]; then
    _apiReady=1
    break
  fi
  echo "Waiting for CSV to be ready"
done

if [ $_apiReady -eq 0 ]; then
  echo "nfd-operator subscription could not install in the allotted time."
  exit 1
fi
echo "nfd-operator installed successfully"

oc get csv -n openshift-nfd $CSVName -o jsonpath='{.metadata.annotations.alm-examples}' | jq '.[0]'  > /tmp/nodefeaturediscovery.json
oc apply -f /tmp/nodefeaturediscovery.json
oc wait nodefeaturediscovery -n openshift-nfd --for=condition=Available --timeout=15m --all
