#!/usr/bin/env bash

# Never emit commands or credential-bearing arguments through shell tracing,
# including when the caller invokes this script with `bash -x`.
set +x
set -o nounset
set -o pipefail
set -o errexit

STATE_FILE="${SHARED_DIR}/aro-hcp.env"
if [[ ! -s "${STATE_FILE}" ]]; then
  echo "No ARO HCP state file found; nothing to delete."
  exit 0
fi

# shellcheck disable=SC1090
source "${STATE_FILE}"

export AZURE_CONFIG_DIR="${SHARED_DIR}/azure-config-delete"
mkdir -p "${AZURE_CONFIG_DIR}"
SP_FILE="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ ! -s "${SP_FILE}" ]]; then
  echo "${SP_FILE} is missing; cannot authenticate for cleanup." >&2
  exit 1
fi

AZURE_CLIENT_ID=$(jq -er '.clientId' "${SP_FILE}")
AZURE_CLIENT_SECRET=$(jq -er '.clientSecret' "${SP_FILE}")
AZURE_TENANT_ID=$(jq -er '.tenantId' "${SP_FILE}")

set +x
az login \
  --service-principal \
  --username "${AZURE_CLIENT_ID}" \
  --password "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --only-show-errors \
  --output none
unset AZURE_CLIENT_SECRET AZURE_TENANT_ID
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"
az extension add --name aro --upgrade --yes --only-show-errors
az aro hcp -h >/dev/null

# Convert a CI duration value into seconds for the deletion deadline.
duration_to_seconds() {
  local value="$1"
  if [[ "${value}" =~ ^([0-9]+)s$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "${value}" =~ ^([0-9]+)m$ ]]; then
    echo $((BASH_REMATCH[1] * 60))
  elif [[ "${value}" =~ ^([0-9]+)h$ ]]; then
    echo $((BASH_REMATCH[1] * 3600))
  elif [[ "${value}" =~ ^[0-9]+$ ]]; then
    echo "${value}"
  else
    echo "Unsupported duration: ${value}" >&2
    return 1
  fi
}

timeout_seconds=$(duration_to_seconds "${ARO_HCP_DELETE_TIMEOUT}")
start_time=${SECONDS}
cleanup_failed=false
cluster_present=false

if az aro hcp cluster show \
  --name "${CLUSTER_NAME}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --only-show-errors \
  --output none 2>/dev/null; then
  cluster_present=true
  if ! az aro hcp cluster delete \
      --name "${CLUSTER_NAME}" \
      --resource-group "${CUSTOMER_RG_NAME}" \
      --yes \
      --no-wait \
      --only-show-errors; then
    echo "Failed to request deletion of ARO HCP ${CLUSTER_NAME}; continuing with resource-group cleanup." >&2
    cleanup_failed=true
  fi

  if [[ "${cleanup_failed}" == false ]]; then
    while (( SECONDS - start_time < timeout_seconds )); do
      if ! az aro hcp cluster show \
        --name "${CLUSTER_NAME}" \
        --resource-group "${CUSTOMER_RG_NAME}" \
        --only-show-errors \
        --output none 2>/dev/null; then
        cluster_present=false
        break
      fi
      echo "Waiting for Azure RP to delete ${CLUSTER_NAME}..."
      sleep 30
    done

    if [[ "${cluster_present}" == true ]]; then
      echo "Timed out waiting for ${CLUSTER_NAME} to be deleted; continuing with resource-group cleanup." >&2
      cleanup_failed=true
    fi
  fi
fi

# The documented delete flow leaves the customer resource group, VNet, and
# subnets behind. Always attempt this cleanup, including when the RP delete
# fails or times out; deleting the group also removes the HCP resource.
rg_exists=""
if ! rg_exists=$(az group exists \
    --name "${CUSTOMER_RG_NAME}" \
    --subscription "${AZURE_SUBSCRIPTION_ID}" \
    --only-show-errors); then
  echo "Failed to determine whether customer resource group ${CUSTOMER_RG_NAME} exists." >&2
  cleanup_failed=true
elif [[ "${rg_exists}" == "true" ]]; then
  if ! az group delete \
      --name "${CUSTOMER_RG_NAME}" \
      --subscription "${AZURE_SUBSCRIPTION_ID}" \
      --yes \
      --only-show-errors; then
    echo "Failed to delete customer resource group ${CUSTOMER_RG_NAME}." >&2
    cleanup_failed=true
  fi
fi

if [[ "${cleanup_failed}" == true ]]; then
  exit 1
fi

echo "Deleted ARO HCP ${CLUSTER_NAME} and customer resource group ${CUSTOMER_RG_NAME}."
