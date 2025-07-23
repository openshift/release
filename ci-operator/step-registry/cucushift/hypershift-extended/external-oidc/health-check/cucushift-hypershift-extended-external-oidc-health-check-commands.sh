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

# Check special fields in authentication.config/cluster
if oc get featuregate cluster -o=jsonpath='{.status.featureGates[*].enabled}' --kubeconfig "${SHARED_DIR}"/nested_kubeconfig | grep -q ExternalOIDCWithUIDAndExtraClaimMappings; then
    # Ensure the extra and uid fields exist and are not empty
    if grep -q '"extra":\[{"key".*"uid":{"' <<< "$hc_authentication_cluster_spec_oidcproviders"; then
        echo "External OIDC uid and extra settings are synced into the hosted cluster"
    else
        echo "$hc_authentication_cluster_spec_oidcproviders"
        echo "External OIDC uid and extra settings are not synced into the hosted cluster!"
        exit 1
    fi
fi

echo "Making sure cm/auth-config on the management cluster is updated"
mc_auth_config="$(oc get cm auth-config -n "clusters-${cluster_name}" -o jsonpath='{.data.auth\.json}')"
if ! grep -i issuer <<< "$mc_auth_config"; then
    echo "cm/auth-config on the management cluster is not updated"
    exit 1
fi

# Further check the special fields in kube-apiserver config
if oc get featuregate cluster -o=jsonpath='{.status.featureGates[*].enabled}' --kubeconfig "${SHARED_DIR}"/nested_kubeconfig | grep -q ExternalOIDCWithUIDAndExtraClaimMappings; then
    # Ensure the extra and uid fields not only exist and but also are not empty
    if grep -q '"extra":\[{"key"' <<< "$mc_auth_config" && grep -q '"uid":{"' <<< "$mc_auth_config"; then
        echo "External OIDC uid and extra settings are configured in kube-apiserver"
    else
        echo "$mc_auth_config"
        echo "External OIDC uid and extra settings are not configured in kube-apiserver!"
        exit 1
    fi
fi

ISSUER_URL="$(</var/run/hypershift-ext-oidc-app-cli/issuer-url)"
CLI_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-cli/client-id)"
CONSOLE_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-console/client-id)"
CONSOLE_CLIENT_SECRET="$(</var/run/hypershift-ext-oidc-app-console/client-secret)"

echo "Getting kube-apiserver address for the hosted cluster"
api_server_url="$(oc get infrastructure cluster -o jsonpath='{.status.apiServerURL}' --kubeconfig "${SHARED_DIR}"/nested_kubeconfig)"
if [[ -z "$api_server_url" ]]; then
    echo "Failed to get kube-apiserver address for the hosted cluster"
    exit 1
fi
echo "kube-apiserver address for the hosted cluster: $api_server_url"

echo "Login to the hosted cluster with the CLI client"
login_output="$(oc login "$api_server_url" --insecure-skip-tls-verify=true --exec-plugin=oc-oidc --issuer-url="$ISSUER_URL" --client-id="$CLI_CLIENT_ID" --extra-scopes=email --callback-port=8080 --kubeconfig=/tmp/kubeconfig-cli)"
if [[ ! "$login_output" =~ "Logged into" ]]; then
    echo "Failed to login to the hosted cluster with the CLI client"
    exit 1
fi
echo "Login output: $login_output"

# TODO: check if the login with the CLI client that is not defined in config is successful

echo "Login to the hosted cluster with the console client"
login_output="$(oc login "$api_server_url" --insecure-skip-tls-verify=true --exec-plugin=oc-oidc --issuer-url="$ISSUER_URL" --client-id="$CONSOLE_CLIENT_ID" --client-secret="$CONSOLE_CLIENT_SECRET" --callback-port=8080 --kubeconfig=/tmp/kubeconfig-console)"
if [[ ! "$login_output" =~ "Logged into" ]]; then
    echo "Failed to login to the hosted cluster with the console client"
    exit 1
fi
echo "Login output: $login_output"




