#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Gathering Quay operator diagnostics..."

# Custom resources
oc get quayregistries --all-namespaces -o json >"$ARTIFACT_DIR/quayregistries.json" || true
oc get noobaas --all-namespaces -o json >"$ARTIFACT_DIR/noobaas.json" || true
oc get quayintegrations -o json >"$ARTIFACT_DIR/quayintegrations.json" || true

# Describe QuayRegistry for human-readable status
oc describe quayregistry --all-namespaces >"$ARTIFACT_DIR/quayregistry-describe.txt" 2>&1 || true

# OLM status
oc get subscriptions --all-namespaces -o yaml >"$ARTIFACT_DIR/olm-subscriptions.yaml" || true
oc get csv --all-namespaces -o yaml >"$ARTIFACT_DIR/olm-csvs.yaml" || true

# Events from relevant namespaces
for ns in quay openshift-operators; do
  oc get events -n "$ns" --sort-by='.lastTimestamp' >"$ARTIFACT_DIR/events-${ns}.txt" 2>&1 || true
done

# Pod logs from relevant namespaces
for ns in quay openshift-operators; do
  oc get pods -n "$ns" -o wide >"$ARTIFACT_DIR/pods-${ns}.txt" 2>&1 || true
  while IFS= read -r pod; do
    for container in $(oc get pod "$pod" -n "$ns" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null); do
      oc logs -n "$ns" "$pod" -c "$container" --tail=500 >"$ARTIFACT_DIR/pod-log-${ns}-${pod}-${container}.log" 2>&1 || true
    done
  done < <(oc get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
done

echo "Quay diagnostics gathering complete."
