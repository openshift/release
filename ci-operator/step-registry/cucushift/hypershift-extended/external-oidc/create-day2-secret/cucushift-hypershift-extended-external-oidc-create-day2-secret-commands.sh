#!/usr/bin/env bash

set -euo pipefail

cluster_name="$(oc get hc -A -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "$cluster_name" ]]; then
    echo "Unable to find the hosted cluster's name"
    exit 1
fi

echo "Waiting for the HC to be Available"
oc wait --timeout=30m --for=condition=Available --namespace=clusters "hostedcluster/${cluster_name}"

echo "Cluster became available, creating kubeconfig"
hypershift create kubeconfig --namespace=clusters --name="${cluster_name}" > "${SHARED_DIR}"/nested_kubeconfig

CONSOLE_CLIENT_SECRET="$(</var/run/hypershift-ext-oidc-app-console/client-secret)"
# The name must match the name of the empty secret created
# in step cucushift-hypershift-extended-external-oidc-enable.
CONSOLE_CLIENT_SECRET_NAME=authid-console-openshift-console

oc create secret generic "$CONSOLE_CLIENT_SECRET_NAME" -n openshift-config \
    --from-literal=clientSecret="$CONSOLE_CLIENT_SECRET" \
    --kubeconfig="${SHARED_DIR}/nested_kubeconfig"
