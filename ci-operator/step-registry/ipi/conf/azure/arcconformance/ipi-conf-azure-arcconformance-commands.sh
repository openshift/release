#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Leased resource is ${LEASED_RESOURCE}"

# TODO we should eventually make sure we only get cluster leases in the correct 
# region. ATM we SKIP testing if the leased is not the expected one.
if [[ "$LEASED_RESOURCE" != "eastus" ]]; then
  echo "================================================"
  echo "Azure Arc-enabled Kubernetes clusters are not" 
  echo "available in ${LEASED_RESOURCE}. Skipping tests."
  echo "================================================"
  exit 0
fi

export PATH=$PATH:/tmp/bin
mkdir /tmp/bin

echo "$(date -u --rfc-3339=seconds) - Installing tools..."

# install sonobuoy
# TODO move to image
curl -L https://github.com/vmware-tanzu/sonobuoy/releases/download/v0.20.0/sonobuoy_0.20.0_linux_amd64.tar.gz | tar xvzf - -C /tmp/bin/ sonobuoy
chmod ug+x /tmp/bin/sonobuoy
sonobuoy version

# install jq
# TODO move to image
curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 > /tmp/bin/jq
chmod ug+x /tmp/bin/jq
jq

# install yq
# TODO move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 > /tmp/bin/yq 
chmod ug+x /tmp/bin/yq
yq --version

# az should already be there
az version

echo "$(date -u --rfc-3339=seconds) - Collecting parameters..."

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(cat ${AZURE_AUTH_LOCATION} | jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(cat ${AZURE_AUTH_LOCATION} | jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(cat ${AZURE_AUTH_LOCATION} | jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(cat ${AZURE_AUTH_LOCATION} | jq -r .subscriptionId)"

CLUSTER_NAME="$(oc get -o jsonpath='{.status.infrastructureName}' infrastructure cluster)"
RESOURCE_GROUP="$(oc get -o jsonpath='{.status.platformStatus.azure.resourceGroupName}' infrastructure cluster)"
REGION="${LEASED_RESOURCE}"
KUBERNETES_DISTRIBUTION="openshift"
DNS_NAMESPACE="openshift-dns"
DNS_POD_LABELS="dns.operator.openshift.io/daemonset-dns"
CONFORMANCE_YAML_PATH="${ARTIFACT_DIR}/conformance.yaml"

echo "$(date -u --rfc-3339=seconds) - Logging in to Azure..."

# log in with az
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}"

echo "$(date -u --rfc-3339=seconds) - Registering Kubernetes provider to Azure subscription..."

# make sure the provider is registered in this Azure subscription
az provider register --namespace Microsoft.Kubernetes --wait

echo "$(date -u --rfc-3339=seconds) - Downloading conformance test suite..."

# download the latest certification conformance suite
curl -L https://raw.githubusercontent.com/Azure/azure-arc-validation/main/conformance.yaml 2>/dev/null > ${CONFORMANCE_YAML_PATH}

echo "$(date -u --rfc-3339=seconds) - Starting test suite from ${CONFORMANCE_YAML_PATH}..."

# run sonobuoy
sonobuoy run --plugin "${CONFORMANCE_YAML_PATH}" \
  --plugin-env azure-arc-conformance.TENANT_ID="${AZURE_AUTH_TENANT_ID}" \
  --plugin-env azure-arc-conformance.SUBSCRIPTION_ID="${AZURE_AUTH_SUBSCRIPTION_ID}" \
  --plugin-env azure-arc-conformance.RESOURCE_GROUP="${RESOURCE_GROUP}" \
  --plugin-env azure-arc-conformance.CLUSTER_NAME="${CLUSTER_NAME}" \
  --plugin-env azure-arc-conformance.LOCATION="${REGION}" \
  --plugin-env azure-arc-conformance.CLIENT_ID="${AZURE_AUTH_CLIENT_ID}" \
  --plugin-env azure-arc-conformance.CLIENT_SECRET="${AZURE_AUTH_CLIENT_SECRET}" \
  --plugin-env azure-arc-conformance.KUBERNETES_DISTRIBUTION="${KUBERNETES_DISTRIBUTION}" \
  --dns-namespace="${DNS_NAMESPACE}" \
  --dns-pod-labels="${DNS_POD_LABELS}"

# wait for the sonobuoy instance to become ready
oc wait pod/sonobuoy -n sonobuoy --for condition=Ready --timeout=30s

# wait for sonobuoy to finish
status="running"
while [[ "$status" =~ "running" ]]; do
  sleep 5
  status=$(sonobuoy status --json | jq -r ".plugins[0].status")
done

echo "$(date -u --rfc-3339=seconds) - Waiting for tests to finish..."

# check sonobuoy run status
result=""
while [[ -z "${result}" ]]; do
  sleep 5
  result=$(sonobuoy status --json | jq -r '.plugins[0]["result-status"]')
done

sonobuoy status

echo "$(date -u --rfc-3339=seconds) - Testing finished, retrieving status and assets..."

sonobuoy retrieve "${ARTIFACT_DIR}"

echo "$(date -u --rfc-3339=seconds) - Tearing down..."

sonobuoy delete

if [[ "$result" =~ "failed" ]]; then
  exit 1
fi
