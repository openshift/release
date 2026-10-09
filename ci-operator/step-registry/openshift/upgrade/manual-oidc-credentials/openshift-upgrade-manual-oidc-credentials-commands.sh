#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

region="${LEASED_RESOURCE}"
kubeconfig="${SHARED_DIR}/kubeconfig"
output_dir="$(mktemp -d)"
credentials_requests_dir="${output_dir}/creds"
pull_secret="${output_dir}/pull_secret"
trap 'rm -rf "${output_dir}"' EXIT

current_version="$(oc get clusterversion version --output=jsonpath='{.status.desired.version}')"
echo "Current cluster version: ${current_version}"
echo "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"

cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${pull_secret}"
KUBECONFIG="" oc registry login --to "${pull_secret}"

oc adm release extract \
  --kubeconfig="${kubeconfig}" \
  --registry-config="${pull_secret}" \
  --credentials-requests \
  --included \
  --to="${credentials_requests_dir}" \
  "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"

oc get secret bound-service-account-signing-key \
  --namespace openshift-kube-apiserver \
  --output=jsonpath='{.data.service-account\.pub}' \
  | base64 --decode > "${output_dir}/serviceaccount-signer.public"

case "${CLUSTER_TYPE}" in
  aws)
    cloud=aws
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

    ccoctl aws create-all \
      --name="${NAMESPACE}-${UNIQUE_HASH}" \
      --region="${region}" \
      --credentials-requests-dir="${credentials_requests_dir}" \
      --output-dir="${output_dir}" \
      --public-key-file="${output_dir}/serviceaccount-signer.public"
    ;;
  gcp)
    cloud=gcp
    export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"

    ccoctl gcp create-all \
      --name="${NAMESPACE}-${UNIQUE_HASH}" \
      --region="${region}" \
      --credentials-requests-dir="${credentials_requests_dir}" \
      --output-dir="${output_dir}" \
      --public-key-file="${output_dir}/serviceaccount-signer.public" \
      --project="$(< "${CLUSTER_PROFILE_DIR}/openshift_gcp_project")"
    ;;
  azure4)
    cloud=azure
    azure_auth_location="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
    AZURE_SUBSCRIPTION_ID="$(tr -d '{}\" ' < "${azure_auth_location}" | tr ',' '\n' | grep subscriptionId | cut -d ':' -f2)"
    AZURE_TENANT_ID="$(tr -d '{}\" ' < "${azure_auth_location}" | tr ',' '\n' | grep tenantId | cut -d ':' -f2)"
    AZURE_CLIENT_ID="$(tr -d '{}\" ' < "${azure_auth_location}" | tr ',' '\n' | grep clientId | cut -d ':' -f2)"
    AZURE_CLIENT_SECRET="$(tr -d '{}\" ' < "${azure_auth_location}" | tr ',' '\n' | grep clientSecret | cut -d ':' -f2)"
    export AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET

    issuer_url="$(oc get authentication cluster --output=jsonpath='{.spec.serviceAccountIssuer}')"
    installation_resource_group="$(oc get infrastructure cluster --output=jsonpath='{.status.platformStatus.azure.resourceGroupName}')"
    base_domain_resource_group="$(grep -m1 'baseDomainResourceGroupName:' "${SHARED_DIR}/install-config.yaml" | cut -d ':' -f2 | tr -d ' ')"

    ccoctl azure create-managed-identities \
      --name="${NAMESPACE}-${JOB_NAME_HASH}" \
      --output-dir="${output_dir}" \
      --region="${region}" \
      --subscription-id="${AZURE_SUBSCRIPTION_ID}" \
      --credentials-requests-dir="${credentials_requests_dir}" \
      --issuer-url="${issuer_url}" \
      --dnszone-resource-group-name="${base_domain_resource_group}" \
      --installation-resource-group-name="${installation_resource_group}" \
      --preserve-existing-roles
    ;;
  *)
    echo "Unsupported cluster type: ${CLUSTER_TYPE}" >&2
    exit 1
    ;;
esac

ccoctl "${cloud}" apply secrets \
  --output-dir="${output_dir}" \
  --kubeconfig="${kubeconfig}"

target_version="$(oc adm release info \
  --registry-config="${pull_secret}" \
  --output=jsonpath='{.metadata.version}' \
  "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}")"

ccoctl "${cloud}" set-upgradeable-to "${target_version}" --kubeconfig="${kubeconfig}"
oc wait --for=condition=Upgradeable=True clusteroperator/cloud-credential --timeout=5m
