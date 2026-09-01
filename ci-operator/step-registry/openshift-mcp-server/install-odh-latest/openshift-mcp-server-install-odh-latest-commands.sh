#!/bin/bash

set -euo pipefail

cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: opendatahub-operator-latest
  namespace: openshift-marketplace
spec:
  image: quay.io/opendatahub/opendatahub-operator-catalog:latest
  sourceType: grpc
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: opendatahub-operator
  namespace: openshift-operators
spec:
  channel: fast
  installPlanApproval: Automatic
  name: opendatahub-operator
  source: opendatahub-operator-latest
  sourceNamespace: openshift-marketplace
EOF

oc wait catalogsource/opendatahub-operator-latest -n openshift-marketplace \
  --for=jsonpath='{.status.connectionState.lastObservedState}'=READY --timeout=10m

csv=""
for _ in $(seq 1 120); do
  csv=$(oc get subscription/opendatahub-operator -n openshift-operators \
    -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  [[ -n "${csv}" ]] && break
  sleep 10
done
if [[ -z "${csv}" ]]; then
  oc get subscription,installplan,csv -n openshift-operators -o wide
  exit 1
fi

oc wait "csv/${csv}" -n openshift-operators \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=20m
oc get catalogsource/opendatahub-operator-latest -n openshift-marketplace -o yaml
oc get "csv/${csv}" -n openshift-operators -o yaml
