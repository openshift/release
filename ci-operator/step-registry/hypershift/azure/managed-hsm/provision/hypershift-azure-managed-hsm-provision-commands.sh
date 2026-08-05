#!/bin/bash

set -euo pipefail

if [[ "${HYPERSHIFT_AZURE_MANAGED_HSM}" != "true" ]]; then
  echo "Managed HSM provisioning is disabled"
  exit 0
fi

retry() {
  local attempts="$1"
  local delay="$2"
  shift 2

  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$@"; then
      return 0
    fi
    if ((attempt == attempts)); then
      echo "Command failed after ${attempts} attempts: $*" >&2
      return 1
    fi
    echo "Attempt ${attempt}/${attempts} failed; retrying in ${delay} seconds"
    sleep "${delay}"
  done
}

AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-self-managed-azure/credentials.json"
WORKLOAD_IDENTITIES_FILE="/etc/hypershift-ci-jobs-self-managed-azure-e2e/workload-identities.json"

AZURE_AUTH_CLIENT_ID="$(jq -er .clientId "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_CLIENT_SECRET="$(jq -er .clientSecret "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_TENANT_ID="$(jq -er .tenantId "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_SUBSCRIPTION_ID="$(jq -er .subscriptionId "${AZURE_AUTH_LOCATION}")"
KMS_CLIENT_ID="$(jq -er .kmsClientID "${WORKLOAD_IDENTITIES_FILE}")"

az cloud set --name AzureCloud
az login \
  --service-principal \
  --username "${AZURE_AUTH_CLIENT_ID}" \
  --password "${AZURE_AUTH_CLIENT_SECRET}" \
  --tenant "${AZURE_AUTH_TENANT_ID}" \
  --output none
az account set --subscription "${AZURE_AUTH_SUBSCRIPTION_ID}"

ADMIN_OBJECT_ID="$(az ad sp show --id "${AZURE_AUTH_CLIENT_ID}" --query id -o tsv)"
KMS_OBJECT_ID="$(az ad sp show --id "${KMS_CLIENT_ID}" --query id -o tsv)"

UNIQUE_SUFFIX="$(printf '%s' "${PROW_JOB_ID}" | sha256sum | cut -c1-16)"
HSM_NAME="hshift-${UNIQUE_SUFFIX}"
RESOURCE_GROUP="${HSM_NAME}-rg"
KEY_NAME="etcd-encryption"

# Write cleanup inputs before provisioning so post steps can remove partial resources.
printf '%s\n' "${HSM_NAME}" > "${SHARED_DIR}/azure_managed_hsm_name"
printf '%s\n' "${RESOURCE_GROUP}" > "${SHARED_DIR}/azure_managed_hsm_resource_group"

az group create \
  --name "${RESOURCE_GROUP}" \
  --location "${HYPERSHIFT_AZURE_MANAGED_HSM_LOCATION}" \
  --tags "prow-job-id=${PROW_JOB_ID}" \
  --output none

az keyvault create \
  --hsm-name "${HSM_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${HYPERSHIFT_AZURE_MANAGED_HSM_LOCATION}" \
  --administrators "${ADMIN_OBJECT_ID}" \
  --retention-days 7 \
  --output none

SECURITY_DOMAIN_DIR="$(mktemp -d)"
trap 'rm -rf "${SECURITY_DOMAIN_DIR}"' EXIT

security_domain_args=()
for index in 0 1 2; do
  openssl req \
    -newkey rsa:2048 \
    -nodes \
    -keyout "${SECURITY_DOMAIN_DIR}/key-${index}.pem" \
    -x509 \
    -days 1 \
    -out "${SECURITY_DOMAIN_DIR}/cert-${index}.pem" \
    -subj "/CN=HyperShiftCI${index}" \
    2>/dev/null
  security_domain_args+=(--sd-wrapping-keys "${SECURITY_DOMAIN_DIR}/cert-${index}.pem")
done

az keyvault security-domain download \
  --hsm-name "${HSM_NAME}" \
  --security-domain-file "${SECURITY_DOMAIN_DIR}/security-domain.json" \
  "${security_domain_args[@]}" \
  --sd-quorum 2 \
  --output none

retry 10 30 az keyvault role assignment create \
  --hsm-name "${HSM_NAME}" \
  --assignee "${ADMIN_OBJECT_ID}" \
  --role "Managed HSM Crypto Officer" \
  --scope "/" \
  --output none

retry 10 30 az keyvault role assignment create \
  --hsm-name "${HSM_NAME}" \
  --assignee "${ADMIN_OBJECT_ID}" \
  --role "Managed HSM Crypto User" \
  --scope "/keys" \
  --output none

retry 12 30 az keyvault key create \
  --hsm-name "${HSM_NAME}" \
  --name "${KEY_NAME}" \
  --kty RSA-HSM \
  --output none

KEY_ID="$(az keyvault key show \
  --hsm-name "${HSM_NAME}" \
  --name "${KEY_NAME}" \
  --query key.kid \
  -o tsv)"

retry 10 30 az keyvault role assignment create \
  --hsm-name "${HSM_NAME}" \
  --assignee "${KMS_OBJECT_ID}" \
  --role "Managed HSM Crypto User" \
  --scope "/keys/${KEY_NAME}" \
  --output none

printf '%s\n' "${KEY_ID}" > "${SHARED_DIR}/azure_managed_hsm_key_id"
echo "Managed HSM key is ready for the HyperShift KMS test"
