#!/bin/bash
set -euo pipefail
export PATH=$PATH:/tmp/bin
mkdir /tmp/bin
curl https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz | tar xvzf - -C /tmp/bin/ oc
chmod ug+x /tmp/bin/oc

export CCM_NAMESPACE="openshift-cloud-controller-manager"

echo "$(date -u --rfc-3339=seconds) - Apply external cloud-controller-manager FeatureGate configuration"

cat <<EOF | oc apply -f -
---
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  annotations:
    include.release.openshift.io/self-managed-high-availability: "true"
    include.release.openshift.io/single-node-developer: "true"
    release.openshift.io/create-only: "true"
  name: cluster
spec:
  customNoUpgrade:
    enabled:
    - ExternalCloudProvider
  featureSet: CustomNoUpgrade
EOF

function waitForCCMDeploymentCreation() {
  while [ "$(oc get deploy -n ${CCM_NAMESPACE} -o name | wc -l)" == 0 ]; do
    echo "$(date -u --rfc-3339=seconds) - Wait for CCCMO operands creation"
    sleep 5
  done
}
export -f waitForCCMDeploymentCreation

timeout --foreground 3m bash -c waitForCCMDeploymentCreation

echo "$(date -u --rfc-3339=seconds) - Wait for operands to be ready"
oc wait --all -n "${CCM_NAMESPACE}" --for=condition=Available=True deployment --timeout=3m


echo "$(date -u --rfc-3339=seconds) - Wait for some time for cluster operators to reconcile feature gate change"
sleep 30

echo "$(date -u --rfc-3339=seconds) - Wait for the imageregistry operator to go available..."
oc wait --all --for=condition=Available=True clusteroperators.config.openshift.io --timeout=10m

echo "$(date -u --rfc-3339=seconds) - Wait for the imageregistry to rollout..."
oc wait --all --for=condition=Progressing=False clusteroperators.config.openshift.io --timeout=30m

echo "$(date -u --rfc-3339=seconds) - Wait until imageregistry config changes are observed by kube-apiserver..."
sleep 60

echo "$(date -u --rfc-3339=seconds) - Waits for kube-apiserver to finish rolling out..."
oc wait --all --for=condition=Progressing=False clusteroperators.config.openshift.io --timeout=30m

oc wait --all --for=condition=Degraded=False clusteroperators.config.openshift.io --timeout=1m

