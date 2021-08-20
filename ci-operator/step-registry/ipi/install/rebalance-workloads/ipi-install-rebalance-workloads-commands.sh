#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function rebalancePods() {
  NS=$1
  LABEL_SELECTOR=$2

  NODE=$(oc get pods -n "${NS}" -l "${LABEL_SELECTOR}" -o jsonpath=\{'.items[*].spec.nodeName'\})

  # If the workload is spread across more than 1 node, we don't need to rebalance its pods
  NODE_COUNT=$(wc -w <<< "${NODE}")
  if [ "${NODE_COUNT}" -ne 1 ]; then
    return
  fi

  oc adm cordon "${NODE}"
  
  # Get all pods except one to keep it on the original node
  PODS=$(oc get pods -n "${NS}" -l "${LABEL_SELECTOR}" -o jsonpath=\{'.items[*].metadata.name'\} | tr ' ' '\n' | head -n-1)

  for POD in $PODS; do
    PVC=$(oc get pod -n "${NS}" "${POD}" -ojson | jq -r '.spec.volumes[] | select(.persistentVolumeClaim!=null) | .persistentVolumeClaim.claimName')
    if [ -n "${PVC}" ]; then
      oc delete pvc -n "${NS}" "${PVC}"
    fi
    oc delete pod -n "${NS}" "${POD}"
  done

  oc adm uncordon "${NODE}"
}

rebalancePods openshift-monitoring "app.kubernetes.io/name=prometheus"
rebalancePods openshift-monitoring "app.kubernetes.io/name=alertmanager"
