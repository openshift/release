#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.namespace}')
CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
CONTROL_PLANE_NS=${HOSTED_CLUSTER_NS}-${CLUSTER_NAME}

echo "Waiting for nested cluster's node count to reach the desired replicas count in the NodePool"
until \
  [[ $(oc get nodepool ${CLUSTER_NAME} -n ${HOSTED_CLUSTER_NS} -o jsonpath='{.spec.replicas}') \
    == $(oc --kubeconfig=${SHARED_DIR}/nested_kubeconfig get nodes --no-headers | wc -l) ]]; do
      echo "$(date --rfc-3339=seconds) Nested cluster's node count is not equal to the desired replicas in the NodePool. Retrying in 30 seconds."
      oc get vmi -n ${CONTROL_PLANE_NS}
      sleep 30s
done
