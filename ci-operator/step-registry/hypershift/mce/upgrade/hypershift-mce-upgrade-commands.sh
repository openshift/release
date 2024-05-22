#!/bin/bash

set -ex

trap 'FRC=$?; debug' EXIT TERM

debug() {
  if (( FRC != 0 )); then
    oc get catalogsource -n openshift-marketplace multiclusterengine-catalog -o yaml
    oc get pod -n multicluster-engine -o wide
    oc get pod -n hypershift -o wide
    oc get subscription -n multicluster-engine multicluster-engine -o yaml
    oc get csv -n multicluster-engine -o yaml
    oc get multiclusterengines multiclusterengine-sample -o yaml
  fi
}

if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi

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

mceRef=$(oc get csv -n multicluster-engine -o custom-columns=NAME:.metadata.name --no-headers | grep multicluster-engine.v || true)
if [ -n "$mceRef" ]; then
  oc delete csv -n multicluster-engine "$mceRef"
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
oc wait --timeout=20m csv -n multicluster-engine --all --for=jsonpath='{.status.phase}'=Succeeded
until oc get multiclusterengines multiclusterengine-sample -ojsonpath="{.status.currentVersion}" | grep -q "$MCE_TARGET_VERSION"; do
  sleep 10
done
until ! oc get pod -n multicluster-engine -o jsonpath='{.items[*].status.conditions[*].status}' | grep -q "False"; do
  sleep 30
done
echo "multiclusterengine upgrade successfully"
until [[ $(oc get deployment -n hypershift operator -o jsonpath='{.status.updatedReplicas}') == $(oc get deployment -n hypershift operator -o jsonpath='{.status.replicas}') ]]; do
    echo "Waiting for updated replicas to match replicas..."
    sleep 10
done
oc wait --timeout=5m --for=condition=Available -n local-cluster ManagedClusterAddOn/hypershift-addon
oc wait --timeout=5m --for=condition=Degraded=False -n local-cluster ManagedClusterAddOn/hypershift-addon
echo "HyperShift operator upgrade successfully"