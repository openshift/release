#!/usr/bin/env bash

# shellcheck disable=SC2034

set -euxo pipefail

# Input:
# 1. key URL e.g. https://<KEYVAULT_NAME>.vault.azure.net/keys/<KEYVAULT_KEY_NAME>/<KEYVAULT_KEY_VERSION>
#
# Outputs:
# 1. keyvault name
# 2. key name
# 3. key version
function parse_key_url() {
    if [[ -z "$1" ]]; then
        echo "The key URL must not be empty"
        return 1
    fi

    local keyvault_name=""
    local keyvault_key_name=""
    local keyvault_key_version=""
    local keyvault_domain_name=""

    keyvault_key_version="${1##*/}"
    keyvault_key_name="$(awk -F '/' '{print $5}' <<< "$1")"
    keyvault_domain_name="$(awk -F '/' '{print $3}' <<< "$1")"
    keyvault_name="${keyvault_domain_name%%.*}"

    echo "$keyvault_name" "$keyvault_key_name" "$keyvault_key_version"
}

# Inputs:
# $1: name of the first global variable
# $2: name of the second global variable
function assert_equal() {
    if [[ -z "$1" ]]; then
        echo "The first variable's name must not be empty" >&2
        return 1
    fi
    if [[ -z "$2" ]]; then
        echo "The second variable's name must not be empty" >&2
        return 1
    fi

    if [[ "${!1}" != "${!2}" ]]; then
        echo "Error: $1=${!1} != $2=${!2}" >&2
        return 1
    fi
}

echo "Getting and parsing the active key's URL"
ACTIVE_KEY_URL=$(<"${SHARED_DIR}/azure_active_key_url")
read -r KEYVAULT_NAME ACTIVE_KEY_NAME ACTIVE_KEY_VERSION <<< "$(parse_key_url "$ACTIVE_KEY_URL")"

echo "Making sure that the active key's info is correctly specified on the HostedCluster resource"
HC_ACTIVE_KEY_NAME="$(oc get hc -A -o jsonpath='{.items[0].spec.secretEncryption.kms.azure.activeKey.keyName}')"
HC_ACTIVE_KV_NAME="$(oc get hc -A -o jsonpath='{.items[0].spec.secretEncryption.kms.azure.activeKey.keyVaultName}')"
HC_ACTIVE_KEY_VERSION="$(oc get hc -A -o jsonpath='{.items[0].spec.secretEncryption.kms.azure.activeKey.keyVersion}')"
assert_equal HC_ACTIVE_KEY_NAME ACTIVE_KEY_NAME
assert_equal HC_ACTIVE_KV_NAME KEYVAULT_NAME
assert_equal HC_ACTIVE_KEY_VERSION ACTIVE_KEY_VERSION

echo "Checking the ValidAzureKMSConfig condition on the HostedCluster resource"
HC_ValidAzureKMSConfig_STATUS="$(oc get hc -A -o jsonpath='{.items[0].status.conditions[?(@.type=="ValidAzureKMSConfig")].status}')"
if [[ "$HC_ValidAzureKMSConfig_STATUS" != "True" ]]; then
    echo "Error: \$HC_ValidAzureKMSConfig_STATUS=$HC_ValidAzureKMSConfig_STATUS != True" >&2
    exit 1
fi

echo "Checking secret encryption/decryption on the HostedCluster"
TEST_SECRET_NAME=test-secret
TEST_SECRET_NAMESPACE=default
TEST_SECRET_KEY=ThisMustBe
TEST_SECRET_VALUE=FullyEncrypted
oc create secret generic "$TEST_SECRET_NAME" -n "$TEST_SECRET_NAMESPACE" \
    --from-literal="$TEST_SECRET_KEY"="$TEST_SECRET_VALUE" --kubeconfig "${SHARED_DIR}/nested_kubeconfig"
TEST_SECRET_CONTENT="$(oc --kubeconfig "${SHARED_DIR}/nested_kubeconfig" \
    extract secret/test-secret -n "$TEST_SECRET_NAMESPACE" --keys "$TEST_SECRET_KEY" --to -)"
if ! grep -q "$TEST_SECRET_VALUE" <<< "$TEST_SECRET_CONTENT"; then
    echo "Error: test secret value $TEST_SECRET_VALUE not found within the decrypted test secret content $TEST_SECRET_CONTENT" >&2
    exit 1
fi

echo "Making sure the test secret is encrypted when stored within ETCD"
HC_NAME="$(oc get hc -A -o jsonpath='{.items[0].metadata.name}')"
HC_NAMESPACE="$(oc get hc -A -o jsonpath='{.items[0].metadata.namespace}')"
# Unencrypted secrets look like the following:
# /kubernetes.io/secrets/default/test-secret.<secret-content>
# Encrypted secrets look like the following:
# /kubernetes.io/secrets/default/test-secret.k8s:enc:kms:v1:<EncryptionConfiguration-provider-name>:.<encrypted-content>
REMOTE_ETCD_COMMAND="/usr/bin/etcdctl get \
    --cacert /etc/etcd/tls/etcd-ca/ca.crt \
    --cert /etc/etcd/tls/client/etcd-client.crt \
    --key /etc/etcd/tls/client/etcd-client.key \
    --endpoints=localhost:2379 \
    /kubernetes.io/secrets/$TEST_SECRET_NAMESPACE/$TEST_SECRET_NAME | hexdump -C | awk -F '|' '{print \$2}' OFS= ORS="
TEST_SECRET_CONTENT_ENCRYPTED="$(oc rsh -n "$HC_NAMESPACE-$HC_NAME" etcd-0 sh -c "$REMOTE_ETCD_COMMAND")"
if [[ -z "$TEST_SECRET_CONTENT_ENCRYPTED" ]]; then
    echo "Error: got empty test secret content from ETCD" >&2
    exit 1
fi
if grep -q "$TEST_SECRET_VALUE" <<< "$TEST_SECRET_CONTENT_ENCRYPTED"; then
    echo "Error: plain text test secret value $TEST_SECRET_VALUE found within the encrypted test secret content" >&2
    exit 1
fi

echo "Cleaning up the test secret"
oc delete secret $TEST_SECRET_NAME -n "$TEST_SECRET_NAMESPACE" --kubeconfig "${SHARED_DIR}/nested_kubeconfig"
