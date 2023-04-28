#!/bin/bash

set -exuo pipefail

# Enable wildcard routes on the management cluster
oc patch ingresscontroller -n openshift-ingress-operator default --type=json -p \
  '[{ "op": "add", "path": "/spec/routeAdmission", "value": {wildcardPolicy: "WildcardsAllowed"}}]'

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"

CLUSTER_NAMESPACE=clusters-${CLUSTER_NAME}

echo "$(date) Creating HyperShift cluster ${CLUSTER_NAME}"
/usr/bin/hypershift create cluster kubevirt \
  --name ${CLUSTER_NAME} \
  --node-pool-replicas ${HYPERSHIFT_NODE_COUNT} \
  --memory 16Gi \
  --cores 4 \
  --pull-secret=/etc/ci-pull-credentials/.dockerconfigjson \
  --release-image ${RELEASE_IMAGE_LATEST}

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=clusters hostedcluster/${CLUSTER_NAME}
echo "Cluster became available, creating kubeconfig"
bin/hypershift create kubeconfig --name=${CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig

sleep 3600
sleep 3600
sleep 3600

if [ "$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')" == "BareMetal" ]; then
  exit 0
fi

echo "Waiting for nested cluster's node count to reach the desired replicas count in the NodePool"
until \
    [[ $(oc get nodepool ${CLUSTER_NAME} -n clusters -o jsonpath='{.spec.replicas}') \
      == $(oc --kubeconfig=${SHARED_DIR}/nested_kubeconfig get nodes --no-headers | wc -l) ]]; do
        echo "$(date --rfc-3339=seconds) Nested cluster's node count is not equal to the desired replicas in the NodePool. Retrying in 30 seconds."
        oc get vmi -n ${CLUSTER_NAMESPACE}
        sleep 30s
done

echo "Waiting for clusteroperators to be ready"
export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig

until \
  oc wait clusterversion/version --for='condition=Available=True' > /dev/null;  do
    echo "$(date --rfc-3339=seconds) Cluster Operators not yet ready"
    oc get clusteroperators 2>/dev/null || true
    sleep 1s
done