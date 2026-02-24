#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc get quayregistries --all-namespaces -o json >"$ARTIFACT_DIR/quayregistries.json" || true
oc get noobaas --all-namespaces -o json >"$ARTIFACT_DIR/noobaas.json" || true
oc get quayintegrations -o json >"$ARTIFACT_DIR/quayintegrations.json" || true

# Collect quay namespace diagnostics
oc -n quay get pods -o json >"$ARTIFACT_DIR/quay-pods.json" || true
oc -n quay get deployments -o json >"$ARTIFACT_DIR/quay-deployments.json" || true
oc -n quay get events --sort-by='.lastTimestamp' -o json >"$ARTIFACT_DIR/quay-events.json" || true

# Collect pod logs for key components
for pod in $(oc -n quay get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    oc -n quay logs "$pod" --all-containers >"$ARTIFACT_DIR/quay-pod-${pod}.log" 2>&1 || true
done
