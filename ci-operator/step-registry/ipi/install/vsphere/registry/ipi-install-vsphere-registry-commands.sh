#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

echo "$(date -u --rfc-3339=seconds) - Configuring image registry with emptyDir..."
oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'


echo "$(date -u --rfc-3339=seconds) - Wait for the imageregistry operator to see that it has work to do..."
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

