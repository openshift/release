#!/bin/bash

set -euo pipefail

if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  exit 1
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

echo "https://$(oc --kubeconfig="$SHARED_DIR"/nested_kubeconfig -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "$SHARED_DIR/hostedcluster_console.url"
echo "hostedcluster_console.url path:$SHARED_DIR/hostedcluster_console.url"
cat "$SHARED_DIR/hostedcluster_console.url"

echo "switch kubeconfig"
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/mgmt_kubeconfig"
cat "${SHARED_DIR}/nested_kubeconfig" > "${SHARED_DIR}/kubeconfig"
echo "hypershift-guest" > "${SHARED_DIR}/cluster-type"