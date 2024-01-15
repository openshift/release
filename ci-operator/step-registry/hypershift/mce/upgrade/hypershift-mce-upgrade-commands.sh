#!/bin/bash

set -ex

_REPO="quay.io/acm-d/mce-custom-registry"
MCE_TARGET_VERSION=${MCE_TARGET_VERSION:-"2.4"}

IMG="${_REPO}:${MCE_TARGET_VERSION}-latest"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: multiclusterengine-catalog
  namespace: openshift-marketplace
spec:
  displayName: MultiCluster Engine
  publisher: Red Hat
  sourceType: grpc
  image: ${IMG}
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

mceRef=`oc get csv -n multicluster-engine -o custom-columns=NAME:.metadata.name --no-headers | grep multicluster-engine.v`
if [ $? -eq 0 ]; then
  oc delete csv -n multicluster-engine ${mceRef}
else
  echo "WARNING: CSV with multicluster-engine was not found in project multicluster-engine."
fi
oc delete subscription -n multicluster-engine multicluster-engine

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: multicluster-engine
  namespace: multicluster-engine
spec:
  channel: stable-${MCE_TARGET_VERSION}
  installPlanApproval: Automatic
  name: multicluster-engine
  source: multiclusterengine-catalog
  sourceNamespace: openshift-marketplace
EOF

CSVName=""
for ((i=1; i<=60; i++)); do
  output=$(oc get subscription multicluster-engine -n multicluster-engine -o jsonpath='{.status.currentCSV}' >> /dev/null && echo "exists" || echo "not found")
  if [ "$output" != "exists" ]; then
    sleep 2
    continue
  fi
  CSVName=$(oc get subscription -n multicluster-engine multicluster-engine -o jsonpath='{.status.currentCSV}')
  if [ "$CSVName" != "" ]; then
    break
  fi
  sleep 10
done
_apiReady=0
echo "* Using CSV: ${CSVName}"
for ((i=1; i<=20; i++)); do
  sleep 30
  output=$(oc get csv -n multicluster-engine $CSVName -o jsonpath='{.status.phase}' >> /dev/null && echo "exists" || echo "not found")
  if [ "$output" != "exists" ]; then
    continue
  fi
  phase=$(oc get csv -n multicluster-engine $CSVName -o jsonpath='{.status.phase}')
  if [ "$phase" == "Succeeded" ]; then
    _apiReady=1
    break
  fi
  echo "Waiting for CSV to be ready"
done

if [ $_apiReady -eq 0 ]; then
  echo "multiclusterengine subscription could not upgrade in the allotted time."
  exit 1
fi
echo "multiclusterengine upgrade successfully"