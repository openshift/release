#!/usr/bin/env bash

set -euo pipefail

CLUSTER_NAME="$(oc get hc -A -o jsonpath='{.items[0].metadata.name}')"
export CLUSTER_NAME
if [[ -z "$CLUSTER_NAME" ]]; then
    echo "Unable to find the hosted cluster's name"
    exit 1
fi

# Wait for the HC to be Available
timeout 25m bash -c "
  until [[ \$(oc get -n clusters hostedcluster/${CLUSTER_NAME} -o jsonpath='{.status.version.history[?(@.state!=\"\")].state}') = Available ]]; do
      sleep 15
  done
"

echo "Getting kubeconfig of the hosted cluster"
hypershift create kubeconfig --namespace=clusters --name="${CLUSTER_NAME}" > "${SHARED_DIR}"/nested_kubeconfig

CONSOLE_CLIENT_SECRET="$(</var/run/hypershift-ext-oidc-app-console/client-secret)"
# The name must match the name of the empty secret created
# in step cucushift-hypershift-extended-external-oidc-enable.
CONSOLE_CLIENT_SECRET_NAME=authid-console-openshift-console

oc create secret generic "$CONSOLE_CLIENT_SECRET_NAME" -n openshift-config \
    --from-literal=clientSecret="$CONSOLE_CLIENT_SECRET" \
    --kubeconfig="${SHARED_DIR}/nested_kubeconfig"
