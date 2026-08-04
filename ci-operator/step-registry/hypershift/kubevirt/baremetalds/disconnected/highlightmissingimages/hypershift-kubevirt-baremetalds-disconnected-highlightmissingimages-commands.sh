#!/bin/bash

set -x

echo "--- Management cluster ---"
oc get pods -A -o yaml | grep "Back-off pulling image" | sort | uniq

echo "--- Hosted cluster ---"
if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
  oc get pods -A -o yaml | grep "Back-off pulling image" | sort | uniq
fi

