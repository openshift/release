#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_name="${NAMESPACE}-${JOB_NAME_HASH}"
region="${LEASED_RESOURCE}"
kubeconfig="${SHARED_DIR}/kubeconfig"
azure_auth_location="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
credentials_requests_dir="$(mktemp -d)"
output_dir="$(mktemp -d)"
pull_secret="$(mktemp)"
trap 'rm -rf "${credentials_requests_dir}" "${output_dir}" "${pull_secret}"' EXIT

AZURE_SUBSCRIPTION_ID="$(tr -d '{}\" ' < "${azure_auth_location}" | tr ',' '\n' | grep subscriptionId | cut -d ':' -f2)"
AZURE_TENANT_ID="$(tr -d '{}\" ' < "${azure_auth_location}" | tr ',' '\n' | grep tenantId | cut -d ':' -f2)"
AZURE_CLIENT_ID="$(tr -d '{}\" ' < "${azure_auth_location}" | tr ',' '\n' | grep clientId | cut -d ':' -f2)"
AZURE_CLIENT_SECRET="$(tr -d '{}\" ' < "${azure_auth_location}" | tr ',' '\n' | grep clientSecret | cut -d ':' -f2)"
export AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET

cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${pull_secret}"
KUBECONFIG="" oc registry login --to "${pull_secret}"

oc adm release extract \
  --registry-config="${pull_secret}" \
  --credentials-requests \
  --cloud=azure \
  --included \
  --install-config="${SHARED_DIR}/install-config.yaml" \
  --to="${credentials_requests_dir}" \
  "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"

issuer_url="$(oc get authentication cluster --output=jsonpath='{.spec.serviceAccountIssuer}')"
installation_resource_group="$(oc get infrastructure cluster --output=jsonpath='{.status.platformStatus.azure.resourceGroupName}')"
base_domain_resource_group="$(grep -m1 'baseDomainResourceGroupName:' "${SHARED_DIR}/install-config.yaml" | cut -d ':' -f2 | tr -d ' ')"

ccoctl azure create-managed-identities \
  --name="${cluster_name}" \
  --output-dir="${output_dir}" \
  --region="${region}" \
  --subscription-id="${AZURE_SUBSCRIPTION_ID}" \
  --credentials-requests-dir="${credentials_requests_dir}" \
  --issuer-url="${issuer_url}" \
  --dnszone-resource-group-name="${base_domain_resource_group}" \
  --installation-resource-group-name="${installation_resource_group}" \
  --preserve-existing-roles

ccoctl azure apply secrets \
  --output-dir="${output_dir}" \
  --kubeconfig="${kubeconfig}"

target_version="$(oc adm release info \
  --registry-config="${pull_secret}" \
  --output=jsonpath='{.metadata.version}' \
  "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}")"

ccoctl azure set-upgradeable-to "${target_version}" --kubeconfig="${kubeconfig}"
oc wait --for=condition=Upgradeable=True clusteroperator/cloud-credential --timeout=5m
