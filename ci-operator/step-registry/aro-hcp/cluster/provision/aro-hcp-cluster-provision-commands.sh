#!/usr/bin/env bash

# Never emit commands or credential-bearing arguments through shell tracing,
# including when the caller invokes this script with `bash -x`.
set +x
set -o errexit
set -o nounset
set -o pipefail

trap 'children=$(jobs -p); if [[ -n "${children}" ]]; then kill ${children} 2>/dev/null || true; wait ${children} 2>/dev/null || true; fi' TERM INT

: "${OPENSHIFT_VERSION:?OPENSHIFT_VERSION must be set}"
: "${WORKER_OPENSHIFT_VERSION:?WORKER_OPENSHIFT_VERSION must be set}"
if [[ ! "${REPLICAS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "REPLICAS must be a positive integer." >&2
  exit 1
fi
if [[ "${MULTI_AZ:-false}" == "true" && ! "${ZONES_COUNT:-}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ZONES_COUNT must be a positive integer when MULTI_AZ=true." >&2
  exit 1
fi

export AZURE_CONFIG_DIR="${SHARED_DIR}/azure-config"
mkdir -p "${AZURE_CONFIG_DIR}"
umask 077

SP_FILE="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ ! -s "${SP_FILE}" ]]; then
  echo "${SP_FILE} is missing from the selected Azure cluster profile." >&2
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

SUBSCRIPTION_ID=$(az account show --query id --output tsv)
az account set --subscription "${SUBSCRIPTION_ID}"

# The Microsoft Learn quickstart requires the ARO CLI extension and Azure CLI
# support for the RP-backed `az aro hcp` command family.
az extension add --name aro --upgrade --yes --only-show-errors
az aro hcp -h >/dev/null

for provider in \
  Microsoft.RedHatOpenShift \
  Microsoft.Compute \
  Microsoft.Storage \
  Microsoft.Authorization; do
  az provider register --namespace "${provider}" --wait --only-show-errors
done

# Normalize a requested cluster name to the Azure resource-name format.
sanitize_name() {
  printf '%s' "$1" \
    | tr '[:upper:]_' '[:lower:]-' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-48
}

if [[ -n "${ARO_HCP_CLUSTER_NAME:-}" ]]; then
  CLUSTER_NAME=$(sanitize_name "${ARO_HCP_CLUSTER_NAME}")
else
  # Match the ROSA HCP CI naming shape while retaining the Azure provider
  # identity: ci-aro-h-<4 random characters>.
  CLUSTER_SUFFIX=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 4)
  CLUSTER_NAME="ci-aro-h-${CLUSTER_SUFFIX}"
fi
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"
# Keep the standard CI cluster identity artifact available to shared steps.
# ARO HCP uses the resource name as its cluster identifier.
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-id"
CUSTOMER_RG_NAME="${ARO_HCP_CUSTOMER_RG_NAME:-${CLUSTER_NAME}-rg}"
CUSTOMER_NSG="${ARO_HCP_CUSTOMER_NSG:-${CLUSTER_NAME}-nsg}"
CUSTOMER_VNET_NAME="${ARO_HCP_CUSTOMER_VNET_NAME:-${CLUSTER_NAME}-vnet}"
CUSTOMER_VNET_SUBNET1="${ARO_HCP_CUSTOMER_VNET_SUBNET1:-${CLUSTER_NAME}-workers}"
CUSTOMER_VNET_INTEGRATION_SUBNET_NAME="${ARO_HCP_CUSTOMER_VNET_INTEGRATION_SUBNET_NAME:-${CLUSTER_NAME}-integration}"
NP_NAME="${WORKER_NODEPOOL_NAME:-workers}"
NODEPOOL_NAMES="${NP_NAME}"
KEYVAULT_NAME="${ARO_HCP_KEYVAULT_NAME:-${CLUSTER_NAME//-/}kv}"
KEYVAULT_NAME=$(printf '%s' "${KEYVAULT_NAME}" | tr -cd '[:alnum:]' | cut -c1-24)
KMS_KEY_NAME="${ARO_HCP_KMS_KEY_NAME:-etcd-kms-key}"

CLUSTER_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${CUSTOMER_RG_NAME}/providers/Microsoft.RedHatOpenShift/hcpOpenShiftClusters/${CLUSTER_NAME}"
STATE_FILE="${SHARED_DIR}/aro-hcp.env"
PROVISION_LOG="${ARTIFACT_DIR}/aro-hcp-cluster-provision.log"
CLUSTER_CONFIG_FILE="${SHARED_DIR}/cluster-config"

# Create the shared JSON metadata file when it does not already exist.
initialize_cluster_config() {
  if [[ -s "${CLUSTER_CONFIG_FILE}" ]] && jq empty "${CLUSTER_CONFIG_FILE}" >/dev/null 2>&1; then
    return
  fi
  jq -n \
    --arg provider "azure" \
    --arg name "${CLUSTER_NAME}" \
    --arg resource_group "${CUSTOMER_RG_NAME}" \
    --arg location "${REGION}" \
    --arg subscription_id "${SUBSCRIPTION_ID}" \
    '{provider: $provider, cluster: {name: $name, resource_group: $resource_group, location: $location, subscription_id: $subscription_id}, timers: {}, nodepools: {}}' \
    > "${CLUSTER_CONFIG_FILE}.tmp"
  mv "${CLUSTER_CONFIG_FILE}.tmp" "${CLUSTER_CONFIG_FILE}"
  chmod 600 "${CLUSTER_CONFIG_FILE}"
}

# Record a numeric cluster-level timer in the shared metadata file.
record_timer() {
  local key="$1"
  local value="$2"
  local tmp
  tmp=$(mktemp "${CLUSTER_CONFIG_FILE}.XXXXXX")
  jq --arg key "${key}" --argjson value "${value}" '.timers[$key] = $value' \
    "${CLUSTER_CONFIG_FILE}" > "${tmp}"
  mv "${tmp}" "${CLUSTER_CONFIG_FILE}"
}

# Record a numeric timer for a worker node pool in shared metadata.
record_nodepool_timer() {
  local nodepool="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp=$(mktemp "${CLUSTER_CONFIG_FILE}.XXXXXX")
  jq --arg nodepool "${nodepool}" --arg key "${key}" --argjson value "${value}" \
    '.nodepools[$nodepool][$key] = $value' "${CLUSTER_CONFIG_FILE}" > "${tmp}"
  mv "${tmp}" "${CLUSTER_CONFIG_FILE}"
}

# Record a string-valued cluster status or state in shared metadata.
record_timer_string() {
  local key="$1"
  local value="$2"
  local tmp
  tmp=$(mktemp "${CLUSTER_CONFIG_FILE}.XXXXXX")
  jq --arg key "${key}" --arg value "${value}" '.timers[$key] = $value' \
    "${CLUSTER_CONFIG_FILE}" > "${tmp}"
  mv "${tmp}" "${CLUSTER_CONFIG_FILE}"
}

# Accumulate the time spent in a control-plane install state.
record_install_state_duration() {
  local state="$1"
  local value="$2"
  local tmp
  tmp=$(mktemp "${CLUSTER_CONFIG_FILE}.XXXXXX")
  jq --arg state "${state}" --argjson value "${value}" \
    '.timers.install[$state] = ((.timers.install[$state] // 0) + $value)' \
    "${CLUSTER_CONFIG_FILE}" > "${tmp}"
  mv "${tmp}" "${CLUSTER_CONFIG_FILE}"
}

# Accumulate the time spent in a node-pool install state.
record_nodepool_state_duration() {
  local nodepool="$1"
  local state="$2"
  local value="$3"
  local tmp
  tmp=$(mktemp "${CLUSTER_CONFIG_FILE}.XXXXXX")
  jq --arg nodepool "${nodepool}" --arg state "${state}" --argjson value "${value}" \
    '.nodepools[$nodepool].install[$state] = ((.nodepools[$nodepool].install[$state] // 0) + $value)' \
    "${CLUSTER_CONFIG_FILE}" > "${tmp}"
  mv "${tmp}" "${CLUSTER_CONFIG_FILE}"
}

# Record the final RP status for a worker node pool.
record_nodepool_status() {
  local nodepool="$1"
  local state="$2"
  local tmp
  tmp=$(mktemp "${CLUSTER_CONFIG_FILE}.XXXXXX")
  jq --arg nodepool "${nodepool}" --arg state "${state}" \
    '.nodepools[$nodepool].status = $state' "${CLUSTER_CONFIG_FILE}" > "${tmp}"
  mv "${tmp}" "${CLUSTER_CONFIG_FILE}"
}

# Map Azure provisioning states to the shared timing-state vocabulary.
normalize_install_state() {
  case "${1,,}" in
    claim|pending) echo "pending" ;;
    waiting) echo "waiting" ;;
    installing|creating|provisioning) echo "installing" ;;
    updating|updatingresources) echo "updating" ;;
    *) echo "${1,,}" ;;
  esac
}

# Persist the names and identifiers needed by later CI steps and cleanup.
write_state() {
  cat >"${STATE_FILE}" <<EOF
AZURE_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}
ARO_HCP_API_VERSION=${ARO_HCP_API_VERSION}
REGION=${REGION}
CLUSTER_NAME=${CLUSTER_NAME}
CUSTOMER_RG_NAME=${CUSTOMER_RG_NAME}
CUSTOMER_NSG=${CUSTOMER_NSG}
CUSTOMER_VNET_NAME=${CUSTOMER_VNET_NAME}
CUSTOMER_VNET_SUBNET1=${CUSTOMER_VNET_SUBNET1}
CUSTOMER_VNET_INTEGRATION_SUBNET_NAME=${CUSTOMER_VNET_INTEGRATION_SUBNET_NAME}
NP_NAME=${NP_NAME}
NODEPOOL_NAMES=${NODEPOOL_NAMES}
KEYVAULT_NAME=${KEYVAULT_NAME}
KMS_KEY_NAME=${KMS_KEY_NAME}
CLUSTER_RESOURCE_ID=${CLUSTER_RESOURCE_ID}
EOF
  chmod 600 "${STATE_FILE}"
}

# Write the names before creating anything so the post step can clean up a
# partially-created run.
write_state
initialize_cluster_config

exec > >(tee -a "${PROVISION_LOG}") 2>&1

echo "Provisioning ARO HCP cluster ${CLUSTER_NAME} in ${REGION}"

az group create \
  --name "${CUSTOMER_RG_NAME}" \
  --subscription "${SUBSCRIPTION_ID}" \
  --location "${REGION}" \
  --only-show-errors \
  --output none

az network nsg create \
  --name "${CUSTOMER_NSG}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --location "${REGION}" \
  --only-show-errors \
  --output none

az network vnet create \
  --name "${CUSTOMER_VNET_NAME}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --location "${REGION}" \
  --address-prefixes "${ARO_HCP_ADDRESS_PREFIX}" \
  --subnet-name "${CUSTOMER_VNET_SUBNET1}" \
  --subnet-prefixes "${ARO_HCP_WORKER_SUBNET_PREFIX}" \
  --nsg "${CUSTOMER_NSG}" \
  --only-show-errors \
  --output none

az network vnet subnet create \
  --name "${CUSTOMER_VNET_INTEGRATION_SUBNET_NAME}" \
  --vnet-name "${CUSTOMER_VNET_NAME}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --address-prefixes "${ARO_HCP_INTEGRATION_SUBNET_PREFIX}" \
  --delegations Microsoft.RedHatOpenShift/hcpOpenShiftClusters \
  --only-show-errors \
  --output none

NSG_ID=$(az network nsg show --name "${CUSTOMER_NSG}" --resource-group "${CUSTOMER_RG_NAME}" --query id --output tsv)
VNET_ID=$(az network vnet show --name "${CUSTOMER_VNET_NAME}" --resource-group "${CUSTOMER_RG_NAME}" --query id --output tsv)
SUBNET_ID=$(az network vnet subnet show --name "${CUSTOMER_VNET_SUBNET1}" --vnet-name "${CUSTOMER_VNET_NAME}" --resource-group "${CUSTOMER_RG_NAME}" --query id --output tsv)
VNET_INTEGRATION_SUBNET_ID=$(az network vnet subnet show --name "${CUSTOMER_VNET_INTEGRATION_SUBNET_NAME}" --vnet-name "${CUSTOMER_VNET_NAME}" --resource-group "${CUSTOMER_RG_NAME}" --query id --output tsv)

declare -A MI_ID
declare -A MI_PID

# Create and record one managed identity used by the HCP deployment.
create_identity() {
  local key="$1"
  local name="${CLUSTER_NAME}-${key}"
  az identity create \
    --name "${name}" \
    --resource-group "${CUSTOMER_RG_NAME}" \
    --only-show-errors \
    --output none
  MI_ID["${key}"]=$(az identity show --name "${name}" --resource-group "${CUSTOMER_RG_NAME}" --query id --output tsv)
  MI_PID["${key}"]=$(az identity show --name "${name}" --resource-group "${CUSTOMER_RG_NAME}" --query principalId --output tsv)
}

for identity in \
  cp-cluster-api-azure \
  cp-control-plane \
  cp-cloud-controller-manager \
  cp-ingress \
  cp-disk-csi-driver \
  cp-file-csi-driver \
  cp-image-registry \
  cp-cloud-network-config \
  cp-kms \
  dp-disk-csi-driver \
  dp-file-csi-driver \
  dp-image-registry \
  service-managed-identity; do
  create_identity "${identity}"
done

READER_ROLE="acdd72a7-3385-48ef-bd42-f606fba81ae7"
HCP_CLUSTER_API_PROVIDER_ROLE="88366f10-ed47-4cc0-9fab-c8a06148393e"
HCP_CONTROL_PLANE_OPERATOR_ROLE="fc0c873f-45e9-4d0d-a7d1-585aab30c6ed"
CLOUD_CONTROLLER_MANAGER_ROLE="a1f96423-95ce-4224-ab27-4e3dc72facd4"
INGRESS_OPERATOR_ROLE="0336e1d3-7a87-462b-b6db-342b63f7802c"
FILE_STORAGE_OPERATOR_ROLE="0d7aedc0-15fd-4a67-a412-efad370c947e"
NETWORK_OPERATOR_ROLE="be7a6435-15ae-4171-8f30-4a343eff9e8f"
IMAGE_REGISTRY_OPERATOR_ROLE="8b32b316-c2f5-4ddf-b05b-83dacd2d08b5"
FEDERATED_CREDENTIAL_ROLE="ef318e2a-8334-4a05-9e4a-295a196c6a6e"
HCP_SERVICE_MI_ROLE="c0ff367d-66d8-445e-917c-583feb0ef0d4"

# Create an Azure role assignment only when the requested assignment is absent.
assign_role() {
  local principal_id="$1"
  local role_id="$2"
  local scope="$3"
  local existing
  existing=$(az role assignment list \
    --assignee-object-id "${principal_id}" \
    --scope "${scope}" \
    --role "${role_id}" \
    --query '[0].id' \
    --output tsv 2>/dev/null || true)
  if [[ -z "${existing}" ]]; then
    az role assignment create \
      --assignee-object-id "${principal_id}" \
      --assignee-principal-type ServicePrincipal \
      --role "${role_id}" \
      --scope "${scope}" \
      --only-show-errors \
      --output none
  fi
}

# Control-plane operator roles.
assign_role "${MI_PID[cp-cluster-api-azure]}" "${HCP_CLUSTER_API_PROVIDER_ROLE}" "${VNET_ID}"
assign_role "${MI_PID[cp-control-plane]}" "${HCP_CONTROL_PLANE_OPERATOR_ROLE}" "${VNET_ID}"
assign_role "${MI_PID[cp-control-plane]}" "${HCP_CONTROL_PLANE_OPERATOR_ROLE}" "${NSG_ID}"
assign_role "${MI_PID[cp-cloud-controller-manager]}" "${CLOUD_CONTROLLER_MANAGER_ROLE}" "${NSG_ID}"
assign_role "${MI_PID[cp-cloud-controller-manager]}" "${CLOUD_CONTROLLER_MANAGER_ROLE}" "${VNET_ID}"
assign_role "${MI_PID[cp-ingress]}" "${INGRESS_OPERATOR_ROLE}" "${VNET_ID}"
assign_role "${MI_PID[cp-file-csi-driver]}" "${FILE_STORAGE_OPERATOR_ROLE}" "${NSG_ID}"
assign_role "${MI_PID[cp-file-csi-driver]}" "${FILE_STORAGE_OPERATOR_ROLE}" "${VNET_ID}"
assign_role "${MI_PID[cp-image-registry]}" "${IMAGE_REGISTRY_OPERATOR_ROLE}" "${VNET_ID}"
assign_role "${MI_PID[cp-cloud-network-config]}" "${NETWORK_OPERATOR_ROLE}" "${VNET_ID}"

# Service managed identity roles.
assign_role "${MI_PID[service-managed-identity]}" "${HCP_SERVICE_MI_ROLE}" "${VNET_ID}"
assign_role "${MI_PID[service-managed-identity]}" "${HCP_SERVICE_MI_ROLE}" "${NSG_ID}"
for identity in \
  cp-cluster-api-azure \
  cp-control-plane \
  cp-cloud-controller-manager \
  cp-ingress \
  cp-disk-csi-driver \
  cp-file-csi-driver \
  cp-image-registry \
  cp-cloud-network-config \
  cp-kms; do
  assign_role "${MI_PID[service-managed-identity]}" "${READER_ROLE}" "${MI_ID[${identity}]}"
done

# Data-plane operator roles.
for identity in dp-disk-csi-driver dp-file-csi-driver dp-image-registry; do
  assign_role "${MI_PID[service-managed-identity]}" "${FEDERATED_CREDENTIAL_ROLE}" "${MI_ID[${identity}]}"
done
assign_role "${MI_PID[dp-file-csi-driver]}" "${FILE_STORAGE_OPERATOR_ROLE}" "${NSG_ID}"
assign_role "${MI_PID[dp-file-csi-driver]}" "${FILE_STORAGE_OPERATOR_ROLE}" "${VNET_ID}"
assign_role "${MI_PID[dp-image-registry]}" "${IMAGE_REGISTRY_OPERATOR_ROLE}" "${VNET_ID}"

az keyvault create \
  --name "${KEYVAULT_NAME}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --location "${REGION}" \
  --enable-rbac-authorization true \
  --only-show-errors \
  --output none

KEYVAULT_ID=$(az keyvault show --name "${KEYVAULT_NAME}" --resource-group "${CUSTOMER_RG_NAME}" --query id --output tsv)
KEY_VAULT_CRYPTO_OFFICER_ROLE="f25e0fa2-a7c8-4377-ade3-9b78c0e5f72e"
KEY_VAULT_CRYPTO_USER_ROLE="12338af0-0e69-4776-bea7-57ae8d297424"

PROVISIONER_OBJECT_ID="${ARO_HCP_PROVISIONER_OBJECT_ID:-}"
if [[ -z "${PROVISIONER_OBJECT_ID}" ]]; then
  PROVISIONER_OBJECT_ID=$(az ad sp show --id "${AZURE_CLIENT_ID}" --query id --output tsv)
fi
assign_role "${PROVISIONER_OBJECT_ID}" "${KEY_VAULT_CRYPTO_OFFICER_ROLE}" "${KEYVAULT_ID}"
assign_role "${MI_PID[cp-kms]}" "${KEY_VAULT_CRYPTO_USER_ROLE}" "${KEYVAULT_ID}"

for attempt in $(seq 1 30); do
  if az keyvault key create \
    --vault-name "${KEYVAULT_NAME}" \
    --name "${KMS_KEY_NAME}" \
    --kty RSA \
    --size 2048 \
    --only-show-errors \
    --output none; then
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    echo "Unable to create the etcd KMS key after role propagation retries." >&2
    exit 1
  fi
  sleep 10
done
KMS_KEY_VERSION=$(az keyvault key show --vault-name "${KEYVAULT_NAME}" --name "${KMS_KEY_NAME}" --query key.kid --output tsv | awk -F/ '{print $NF}')

sleep "${ARO_HCP_ROLE_PROPAGATION_DELAY}"

CONTROL_PLANE_INSTALL_START=$(date +%s)
record_timer "global_start" "${CONTROL_PLANE_INSTALL_START}"
record_timer "control_plane_install_start" "${CONTROL_PLANE_INSTALL_START}"

az aro hcp cluster create \
  --name "${CLUSTER_NAME}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --location "${REGION}" \
  --version "${OPENSHIFT_VERSION}" \
  --subnet-id "${SUBNET_ID}" \
  --vnet-integration-subnet-id "${VNET_INTEGRATION_SUBNET_ID}" \
  --nsg "${NSG_ID}" \
  --kms-vault-name "${KEYVAULT_NAME}" \
  --vault-visibility Public \
  --kms-active-key "{name:${KMS_KEY_NAME},version:${KMS_KEY_VERSION}}" \
  --assign-service-managed-identity "${MI_ID[service-managed-identity]}" \
  --assign-control-plane-operator-identity cluster-api-azure "${MI_ID[cp-cluster-api-azure]}" \
  --assign-control-plane-operator-identity control-plane "${MI_ID[cp-control-plane]}" \
  --assign-control-plane-operator-identity cloud-controller-manager "${MI_ID[cp-cloud-controller-manager]}" \
  --assign-control-plane-operator-identity ingress "${MI_ID[cp-ingress]}" \
  --assign-control-plane-operator-identity disk-csi-driver "${MI_ID[cp-disk-csi-driver]}" \
  --assign-control-plane-operator-identity file-csi-driver "${MI_ID[cp-file-csi-driver]}" \
  --assign-control-plane-operator-identity image-registry "${MI_ID[cp-image-registry]}" \
  --assign-control-plane-operator-identity cloud-network-config "${MI_ID[cp-cloud-network-config]}" \
  --assign-control-plane-operator-identity kms "${MI_ID[cp-kms]}" \
  --assign-data-plane-operator-identity disk-csi-driver "${MI_ID[dp-disk-csi-driver]}" \
  --assign-data-plane-operator-identity file-csi-driver "${MI_ID[dp-file-csi-driver]}" \
  --assign-data-plane-operator-identity image-registry "${MI_ID[dp-image-registry]}" \
  --only-show-errors

# Convert a CI duration value into seconds for polling deadlines.
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

# Poll the Azure RP until the hosted control plane reaches a terminal state.
wait_for_cluster() {
  local timeout_seconds
  timeout_seconds=$(duration_to_seconds "${READY_WAIT_TIMEOUT}")
  local deadline=$((SECONDS + timeout_seconds))
  local previous_state=""
  local state_start="${CONTROL_PLANE_INSTALL_START}"
  while (( SECONDS < deadline )); do
    local state current_time state_key elapsed
    state=$(az aro hcp cluster show \
      --name "${CLUSTER_NAME}" \
      --resource-group "${CUSTOMER_RG_NAME}" \
      --query properties.provisioningState \
      --output tsv 2>/dev/null || true)
    echo "HCP ${CLUSTER_NAME} provisioningState=${state:-NotFound}"
    current_time=$(date +%s)
    if [[ -n "${state}" ]]; then
      state_key=$(normalize_install_state "${state}")
      if [[ -z "${previous_state}" ]]; then
        previous_state="${state_key}"
      elif [[ "${state_key}" != "${previous_state}" ]]; then
        elapsed=$((current_time - state_start))
        record_install_state_duration "${previous_state}" "${elapsed}"
        previous_state="${state_key}"
        state_start="${current_time}"
      fi
    fi
    case "${state}" in
      Succeeded)
        record_timer_string "status" "${state}"
        return 0
        ;;
      Failed|Canceled|Cancelled|Error)
        if [[ -n "${previous_state}" ]]; then
          record_install_state_duration "${previous_state}" "$((current_time - state_start))"
        fi
        record_timer_string "status" "${state}"
        return 1
        ;;
    esac
    sleep 30
  done
  if [[ -n "${previous_state}" ]]; then
    record_install_state_duration "${previous_state}" "$(( $(date +%s) - state_start ))"
  fi
  record_timer_string "status" "timeout"
  echo "Timed out waiting for HCP ${CLUSTER_NAME}." >&2
  return 1
}

# Normalize a comma- or space-separated zone list and remove duplicates.
normalize_zones() {
  tr ', ' '\n' <<<"$1" | awk 'NF && !seen[$0]++' | sort -V
}

# Query Azure for zones where the worker VM SKU is available.
discover_availability_zones() {
  local sku_json
  if ! sku_json=$(az vm list-skus \
    --location "${REGION}" \
    --resource-type virtualMachines \
    --size "${COMPUTE_MACHINE_TYPE}" \
    --zone \
    --output json); then
    echo "Unable to query VM SKU availability for ${COMPUTE_MACHINE_TYPE} in ${REGION}." >&2
    return 1
  fi

  jq -r \
    --arg location "${REGION}" \
    --arg size "${COMPUTE_MACHINE_TYPE}" \
    '[.[] | select(.name == $size) | .locationInfo[]? |
      select((.location | ascii_downcase) == ($location | ascii_downcase)) |
      .zones[]?] | unique | .[]' <<<"${sku_json}" | sort -V -u
}

# Select the configured or discovered zones for worker node pools.
select_worker_zones() {
  local candidates
  local -a candidates_array
  if [[ "${MULTI_AZ:-false}" == "true" ]]; then
    if [[ -n "${MP_ZONES:-}" ]]; then
      candidates=$(normalize_zones "${MP_ZONES}")
      echo "Using configured worker availability-zone override: $(tr '\n' ' ' <<<"${candidates}")" >&2
    else
      candidates=$(discover_availability_zones)
      echo "Discovered worker availability zones for ${COMPUTE_MACHINE_TYPE} in ${REGION}: $(tr '\n' ' ' <<<"${candidates}")" >&2
    fi
    if [[ -z "${candidates}" ]]; then
      echo "No availability zones are available for ${COMPUTE_MACHINE_TYPE} in ${REGION}." >&2
      return 1
    fi
    mapfile -t candidates_array < <(head -n "${ZONES_COUNT}" <<<"${candidates}")
    if (( ${#candidates_array[@]} != ZONES_COUNT )); then
      echo "Requested ${ZONES_COUNT} zones, but only $(wc -l <<<"${candidates}" | xargs) are available." >&2
      return 1
    fi
    printf '%s\n' "${candidates_array[@]}"
    return 0
  fi

  if [[ -n "${MP_ZONE:-}" ]]; then
    printf '%s\n' "${MP_ZONE}"
  else
    printf '\n'
  fi
}

# Build the worker node-pool name, adding a zone suffix for multi-AZ pools.
worker_nodepool_name_for_zone() {
  local zone="$1"
  if [[ "${MULTI_AZ:-false}" != "true" ]]; then
    printf '%s\n' "${NP_NAME}"
  else
    printf '%s-az%s\n' "${NP_NAME}" "${zone}"
  fi
}

# Poll the Azure RP until one worker node pool reaches a terminal state.
wait_for_nodepool() {
  local nodepool_name="$1"
  local nodepool_install_start="$2"
  local timeout_seconds
  timeout_seconds=$(duration_to_seconds "${READY_WAIT_TIMEOUT}")
  local deadline=$((SECONDS + timeout_seconds))
  local previous_state=""
  local state_start="${nodepool_install_start}"
  while (( SECONDS < deadline )); do
    local state current_time state_key elapsed
    state=$(az aro hcp cluster nodepool show \
      --cluster-name "${CLUSTER_NAME}" \
      --name "${nodepool_name}" \
      --resource-group "${CUSTOMER_RG_NAME}" \
      --query properties.provisioningState \
      --output tsv 2>/dev/null || true)
    echo "Node pool ${nodepool_name} provisioningState=${state:-NotFound}"
    current_time=$(date +%s)
    if [[ -n "${state}" ]]; then
      state_key=$(normalize_install_state "${state}")
      if [[ -z "${previous_state}" ]]; then
        previous_state="${state_key}"
      elif [[ "${state_key}" != "${previous_state}" ]]; then
        elapsed=$((current_time - state_start))
        record_nodepool_state_duration "${nodepool_name}" "${previous_state}" "${elapsed}"
        previous_state="${state_key}"
        state_start="${current_time}"
      fi
    fi
    case "${state}" in
      Succeeded)
        record_nodepool_status "${nodepool_name}" "${state}"
        return 0
        ;;
      Failed|Canceled|Cancelled|Error)
        if [[ -n "${previous_state}" ]]; then
          record_nodepool_state_duration "${nodepool_name}" "${previous_state}" "$((current_time - state_start))"
        fi
        record_nodepool_status "${nodepool_name}" "${state}"
        return 1
        ;;
    esac
    sleep 30
  done
  if [[ -n "${previous_state}" ]]; then
    record_nodepool_state_duration "${nodepool_name}" "${previous_state}" "$(( $(date +%s) - state_start ))"
  fi
  record_nodepool_status "${nodepool_name}" "timeout"
  echo "Timed out waiting for node pool ${nodepool_name}." >&2
  return 1
}

wait_for_cluster

CONTROL_PLANE_READY=$(date +%s)
record_timer "control_plane_ready" "${CONTROL_PLANE_READY}"
record_timer "control_plane_install_seconds" "$((CONTROL_PLANE_READY - CONTROL_PLANE_INSTALL_START))"

# Create one worker node pool, wait for it, and record its install timers.
create_worker_nodepool() {
  local nodepool_name="$1"
  local availability_zone="$2"
  local replicas="$3"
  local nodepool_install_start nodepool_rp_ready
  local -a nodepool_args

  nodepool_args=(
    --cluster-name "${CLUSTER_NAME}"
    --name "${nodepool_name}"
    --resource-group "${CUSTOMER_RG_NAME}"
    --replicas "${replicas}"
    --vm-size "${COMPUTE_MACHINE_TYPE}"
    --version "${WORKER_OPENSHIFT_VERSION}"
    --only-show-errors
  )
  if [[ -n "${availability_zone}" ]]; then
    nodepool_args+=(--availability-zone "${availability_zone}")
  fi

  echo "Creating worker node pool ${nodepool_name} with ${replicas} replicas${availability_zone:+ in availability zone ${availability_zone}}."
  nodepool_install_start=$(date +%s)
  record_nodepool_timer "${nodepool_name}" "install_start" "${nodepool_install_start}"
  az aro hcp cluster nodepool create "${nodepool_args[@]}"
  wait_for_nodepool "${nodepool_name}" "${nodepool_install_start}"

  nodepool_rp_ready=$(date +%s)
  record_nodepool_timer "${nodepool_name}" "rp_ready" "${nodepool_rp_ready}"
  record_nodepool_timer "${nodepool_name}" "install_seconds" "$((nodepool_rp_ready - nodepool_install_start))"
  echo "Worker node pool ${nodepool_name} is ready."
}

if ! WORKER_ZONE_LIST=$(select_worker_zones); then
  echo "Unable to select availability zones for the worker node pool(s)." >&2
  exit 1
fi
if [[ -n "${WORKER_ZONE_LIST}" ]]; then
  mapfile -t WORKER_ZONES < <(printf '%s\n' "${WORKER_ZONE_LIST}")
else
  WORKER_ZONES=("")
fi

if (( ${#WORKER_ZONES[@]} > 1 )); then
  if (( REPLICAS % ${#WORKER_ZONES[@]} != 0 )); then
    echo "REPLICAS (${REPLICAS}) must be evenly divisible by ZONES_COUNT (${#WORKER_ZONES[@]}) for MULTI_AZ=true." >&2
    exit 1
  fi
  WORKER_REPLICAS_PER_ZONE=$((REPLICAS / ${#WORKER_ZONES[@]}))
else
  WORKER_REPLICAS_PER_ZONE="${REPLICAS}"
fi

WORKER_NODEPOOL_NAMES=()
for availability_zone in "${WORKER_ZONES[@]}"; do
  nodepool_name=$(worker_nodepool_name_for_zone "${availability_zone}")
  WORKER_NODEPOOL_NAMES+=("${nodepool_name}")
done
NODEPOOL_NAMES=$(IFS=,; echo "${WORKER_NODEPOOL_NAMES[*]}")
printf '%s\n' "${WORKER_NODEPOOL_NAMES[@]}" >"${SHARED_DIR}/aro-hcp-worker-nodepools"
printf '%s\n' "${WORKER_ZONES[@]}" >"${SHARED_DIR}/aro-hcp-worker-zones"
write_state

WORKER_INSTALL_START=$(date +%s)
for index in "${!WORKER_ZONES[@]}"; do
  create_worker_nodepool \
    "${WORKER_NODEPOOL_NAMES[${index}]}" \
    "${WORKER_ZONES[${index}]}" \
    "${WORKER_REPLICAS_PER_ZONE}"
done
WORKER_RP_READY=$(date +%s)
record_timer "nodepool_install_seconds" "$((WORKER_RP_READY - WORKER_INSTALL_START))"

az aro hcp cluster request-credential \
  --admin \
  --name "${CLUSTER_NAME}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --file "${SHARED_DIR}/kubeconfig" \
  --only-show-errors
chmod 600 "${SHARED_DIR}/kubeconfig"
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/nested_kubeconfig"
chmod 600 "${SHARED_DIR}/nested_kubeconfig"

if command -v oc >/dev/null 2>&1; then
  KUBECONFIG="${SHARED_DIR}/kubeconfig" oc get clusterversion --request-timeout=60s
fi

write_state
echo "ARO HCP cluster ${CLUSTER_NAME} and worker node pools ${NODEPOOL_NAMES} are ready."
