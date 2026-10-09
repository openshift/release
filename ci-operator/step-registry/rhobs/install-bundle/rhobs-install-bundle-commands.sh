#!/bin/bash
set -euo pipefail

oc create namespace coo
oc label namespace coo openshift.io/cluster-monitoring=true
operator-sdk run bundle -n coo --timeout=20m --install-mode=AllNamespaces --verbose "$OO_BUNDLE"
if [ -e "${SHARED_DIR}/coo-csv.yml" ]; then
  rm -f "${SHARED_DIR}/coo-csv.yml"
fi
tries=30
while [[ $tries -gt 0 ]] && ! oc -n coo rollout status deploy/obo-prometheus-operator; do
  sleep 10
  tries=$((tries - 1))
done
oc wait -n coo --for=condition=Available deploy/obo-prometheus-operator --timeout=300s
oc wait -n coo --for=condition=Available deploy/obo-prometheus-operator-admission-webhook --timeout=300s
oc wait -n coo --for=condition=Available deploy/observability-operator --timeout=300s
CSV_NAME=$(oc -n coo get csv | grep 'observability-operator' | awk '{print $1}')
oc -n coo get csv "$CSV_NAME" -oyaml > "${SHARED_DIR}/coo-csv.yml"
