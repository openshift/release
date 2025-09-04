#!/usr/bin/env bash

set -euxo pipefail

if [[ ! -f "${SHARED_DIR}/hosted_cluster_version" ]]; then
    echo "File ${SHARED_DIR}/hosted_cluster_version not available"
    exit 1
fi

HOSTED_CLUSTER_VERSION=$(<"${SHARED_DIR}/hosted_cluster_version")
if [[ $(awk "BEGIN {print ($HOSTED_CLUSTER_VERSION >= 4.19)}") != "1" ]]; then
    echo "Skipping day2 secret creation for OCP <=4.18 clusters"
    exit 0
fi

cluster_name="$(oc get hc -A -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "$cluster_name" ]]; then
    echo "Unable to find the hosted cluster's name"
    exit 1
fi

echo "Waiting for the HC to be Available"
oc wait --timeout=15m --for=condition=Available --namespace=clusters "hostedcluster/${cluster_name}"

# Workaround for limitations of console operator, see OCPSTRAT-2173.
echo "Waiting for the console operator to be degraded"
timeout=1800 # 30min
SECONDS=0
until [[ "$(oc get -n clusters hostedcluster/"${cluster_name}" -ojsonpath='{.status.conditions[?(@.type=="ClusterVersionSucceeding")]}' | grep "False" | grep "ClusterOperatorDegraded" | grep "Cluster operator console is degraded")" != "" ]]; do
    sleep 15
    if (( SECONDS >= timeout )); then
        exit 1
    fi
done

echo "Cluster became available, creating kubeconfig"
hypershift create kubeconfig --namespace=clusters --name="${cluster_name}" > "${SHARED_DIR}"/nested_kubeconfig

set +x
CONSOLE_CLIENT_SECRET="$(</var/run/hypershift-ext-oidc-app-console/client-secret)"
# The name must match the name of the empty secret created
# in step cucushift-hypershift-extended-external-oidc-enable.
CONSOLE_CLIENT_SECRET_NAME=authid-console-openshift-console

oc create secret generic "$CONSOLE_CLIENT_SECRET_NAME" -n openshift-config \
    --from-literal=clientSecret="$CONSOLE_CLIENT_SECRET" \
    --kubeconfig="${SHARED_DIR}/nested_kubeconfig"
