#!/bin/bash

set -u

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

namespace=openshift-lvm-storage
oc get clusterversion version -o json > "${ARTIFACT_DIR}/clusterversion.json" || true
oc get nodes -o wide > "${ARTIFACT_DIR}/nodes.txt" || true
oc get csidriver topolvm.io -o yaml > "${ARTIFACT_DIR}/topolvm-csidriver.yaml" || true
oc -n "${namespace}" get lvmcluster,csv,installplan,subscription,pods -o yaml > "${ARTIFACT_DIR}/lvms-resources.yaml" || true
oc -n "${namespace}" get events --sort-by=.lastTimestamp > "${ARTIFACT_DIR}/lvms-events.txt" || true

for pod in $(oc -n "${namespace}" get pods -o name 2>/dev/null); do
  name=${pod#pod/}
  oc -n "${namespace}" describe "${pod}" > "${ARTIFACT_DIR}/${name}-describe.txt" || true
  oc -n "${namespace}" logs "${pod}" --all-containers --tail=1000 > "${ARTIFACT_DIR}/${name}-logs.txt" 2>&1 || true
done
