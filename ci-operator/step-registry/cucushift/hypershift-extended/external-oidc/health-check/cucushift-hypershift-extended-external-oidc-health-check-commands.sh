#!/usr/bin/env bash

set -euxo pipefail

echo "Waiting for the HC to be ready"
cluster_name="$(oc get hc -A -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "$cluster_name" ]]; then
    echo "Unable to find the hosted cluster's name"
    exit 1
fi

timeout=2700 # 45min
interval=15
SECONDS=0
until [[ "$(oc get -n clusters hostedcluster/"${cluster_name}" -o jsonpath='{.status.version.history[?(@.state!="")].state}')" == Completed ]]; do
    sleep $interval
    if (( SECONDS >= timeout )); then
        echo "Timed out waiting for the hosted cluster to become ready after $timeout seconds"
        exit 1
    fi
done

echo "Getting kubeconfig of the hosted cluster"
hypershift create kubeconfig --namespace=clusters --name="${cluster_name}" > "${SHARED_DIR}"/nested_kubeconfig

echo "Making sure hc.spec.configuration.authentication is synced into the hosted cluster"
hc_authentication_cluster_spec_type="$(oc get authentication cluster -o jsonpath='{.spec.type}' --kubeconfig "${SHARED_DIR}"/nested_kubeconfig)"
if [[ "$hc_authentication_cluster_spec_type" != OIDC ]]; then
    echo "Expect the authentication type of the hosted cluster to be OIDC but found $hc_authentication_cluster_spec_type"
    exit 1
fi
hc_authentication_cluster_spec_oidcproviders="$(oc get authentication cluster -o jsonpath='{.spec.oidcProviders}' --kubeconfig "${SHARED_DIR}"/nested_kubeconfig)"
if [[ -z "$hc_authentication_cluster_spec_oidcproviders" ]]; then
    echo "hc.spec.configuration.authentication is not synced into the hosted cluster"
    exit 1
fi

echo "Making sure cm/auth-config on the management cluster is updated"
mc_auth_config="$(oc get cm auth-config -n "clusters-${cluster_name}" -o jsonpath='{.data.auth\.json}')"
if ! grep -i issuer <<< "$mc_auth_config"; then
    echo "cm/auth-config on the management cluster is not updated"
    exit 1
fi
