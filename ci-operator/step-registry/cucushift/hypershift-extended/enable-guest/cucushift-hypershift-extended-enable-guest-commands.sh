#!/bin/bash

set -xeuo pipefail

if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  exit 1
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
NAMESPACE="clusters"
CLUSTER_NAME=$(oc get hostedclusters -n clusters -o=jsonpath='{.items[0].metadata.name}')

kubedamin_password=$(oc get secret -n "$NAMESPACE-$CLUSTER_NAME" kubeadmin-password --template='{{.data.password | base64decode}}')
echo $kubedamin_password > "$SHARED_DIR/hostedcluster_kubedamin_password"
echo "hostedcluster_kubedamin_password path:$SHARED_DIR/hostedcluster_kubedamin_password"
cat "$SHARED_DIR/hostedcluster_kubedamin_password"
echo "https://$(oc --kubeconfig="$SHARED_DIR"/hostedcluster.kubeconfig -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "$SHARED_DIR/hostedcluster_console.url"
echo "hostedcluster_console.url path:$SHARED_DIR/hostedcluster_console.url"
cat "$SHARED_DIR/hostedcluster_console.url"

echo "switch kubeconfig"
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/mgmt_kubeconfig"
cat "${SHARED_DIR}/nested_kubeconfig" > "${SHARED_DIR}/kubeconfig"