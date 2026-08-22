#!/bin/bash
set -euo pipefail

echo "Waiting for redhat-operators catalog source to be created..."
for i in $(seq 1 60); do
  oc get catalogsource/redhat-operators -n openshift-marketplace && break
  echo "  attempt $i/60 - not found yet, retrying in 5s..."
  sleep 5
done
echo "Waiting for redhat-operators catalog source to be READY..."
oc wait catalogsource/redhat-operators -n openshift-marketplace \
  --for=jsonpath='{.status.connectionState.lastObservedState}'=READY \
  --timeout=600s
echo "redhat-operators catalog source is READY"
