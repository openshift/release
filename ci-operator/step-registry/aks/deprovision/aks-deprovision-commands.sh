#!/usr/bin/env bash

set -euo pipefail

# Azure CLI does not consistently retry DNS and lower-level transport failures.
# Keep direct retries scoped to safe repeats. Retried resource mutations below
# reconcile desired state before issuing another request.
# BEGIN AZURE CLI RETRY HELPER
AZURE_CLI_TRANSIENT_ERROR_PATTERN='NameResolutionError|Temporary failure in name resolution|Name or service not known|Failed to resolve|Could not resolve host|requests\.exceptions\.(ConnectionError|ConnectTimeout|ReadTimeout)|urllib3\.exceptions\.(NewConnectionError|ConnectTimeoutError|ReadTimeoutError)|RemoteDisconnected|Connection (reset|aborted|refused)|connect(ion)?[^:]* timed out|Read timed out|TLS handshake timeout|network is unreachable'

run_az_with_retry() {
  local operation="$1"
  shift

  local max_attempts=4
  local delay=5
  local max_delay=20
  local attempt=1
  local rc=0
  local capture_dir
  capture_dir="$(mktemp -d)"

  while true; do
    : >"${capture_dir}/stdout"
    : >"${capture_dir}/stderr"

    if "$@" >"${capture_dir}/stdout" 2>"${capture_dir}/stderr"; then
      cat "${capture_dir}/stdout"
      if [[ -s "${capture_dir}/stderr" ]]; then
        printf 'Azure CLI %s completed with status 0; command diagnostics suppressed\n' "${operation}" >&2
      fi
      rm -rf "${capture_dir}"
      return 0
    else
      rc=$?
    fi

    # Keep failed output private: stdout must not satisfy a caller's command
    # substitution, while stderr is used only for quiet retry classification.

    if ((rc >= 128 && rc <= 192)); then
      printf 'Azure CLI %s ended with status %d\n' "${operation}" "${rc}" >&2
      rm -rf "${capture_dir}"
      return "${rc}"
    fi

    if ! grep -Eiq "${AZURE_CLI_TRANSIENT_ERROR_PATTERN}" "${capture_dir}/stderr"; then
      printf 'Azure CLI %s failed with non-retryable status %d\n' "${operation}" "${rc}" >&2
      rm -rf "${capture_dir}"
      return "${rc}"
    fi

    if ((attempt >= max_attempts)); then
      printf 'Azure CLI %s failed after %d attempts with transient status %d\n' "${operation}" "${max_attempts}" "${rc}" >&2
      rm -rf "${capture_dir}"
      return "${rc}"
    fi

    printf 'Azure CLI %s hit transient status %d (attempt %d/%d); retrying in %ds\n' "${operation}" "${rc}" "${attempt}" "${max_attempts}" "${delay}" >&2
    if sleep "${delay}"; then
      :
    else
      rc=$?
      printf 'Azure CLI %s retry wait ended with status %d\n' "${operation}" "${rc}" >&2
      rm -rf "${capture_dir}"
      return "${rc}"
    fi
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    if ((delay > max_delay)); then
      delay="${max_delay}"
    fi
  done
}
# END AZURE CLI RETRY HELPER

# Reconcile desired state after an ambiguous mutation response before retrying.
# BEGIN AZURE CLI MUTATION RETRY HELPER
run_az_mutation_with_reconcile() {
  local operation="${1}"
  local state_check="${2}"
  shift 2

  local state_args=()
  local found_delimiter=false
  while (($#)); do
    if [[ "${1}" == "--" ]]; then
      found_delimiter=true
      shift
      break
    fi
    state_args+=("${1}")
    shift
  done
  if [[ "${found_delimiter}" != true || $# -eq 0 ]]; then
    echo "Azure CLI ${operation} retry configuration is invalid" >&2
    return 2
  fi

  local max_attempts=4
  local delay=5
  local max_delay=20
  local attempt=1
  local mutation_rc=0
  local state_rc=0
  local mutation_was_retryable=false
  local capture_dir
  local AZURE_CLI_DESIRED_STATE=false

  if "${state_check}" "${state_args[@]}"; then
    :
  else
    state_rc=$?
    return "${state_rc}"
  fi
  if [[ "${AZURE_CLI_DESIRED_STATE}" == true ]]; then
    echo "Azure CLI ${operation}: desired state is already satisfied"
    return 0
  fi

  capture_dir="$(mktemp -d)"
  while true; do
    : >"${capture_dir}/stdout"
    : >"${capture_dir}/stderr"

    if "$@" >"${capture_dir}/stdout" 2>"${capture_dir}/stderr"; then
      cat "${capture_dir}/stdout"
      if [[ -s "${capture_dir}/stderr" ]]; then
        printf 'Azure CLI %s completed with status 0; command diagnostics suppressed\n' "${operation}" >&2
      fi
      rm -rf "${capture_dir}"
      return 0
    else
      mutation_rc=$?
    fi

    # Keep failed output private while using stderr for quiet classification.

    if ((mutation_rc >= 128 && mutation_rc <= 192)); then
      printf 'Azure CLI %s ended with status %d\n' "${operation}" "${mutation_rc}" >&2
      rm -rf "${capture_dir}"
      return "${mutation_rc}"
    fi

    mutation_was_retryable=false
    if grep -Eiq "${AZURE_CLI_TRANSIENT_ERROR_PATTERN}" "${capture_dir}/stderr"; then
      mutation_was_retryable=true
    elif grep -Fqi 'RoleAssignmentExists' "${capture_dir}/stderr"; then
      mutation_was_retryable=true
    fi

    # The request may have reached Azure even though the response was lost.
    # Check desired state before deciding whether another mutation is safe.
    AZURE_CLI_DESIRED_STATE=false
    if "${state_check}" "${state_args[@]}"; then
      :
    else
      state_rc=$?
      rm -rf "${capture_dir}"
      return "${state_rc}"
    fi
    if [[ "${AZURE_CLI_DESIRED_STATE}" == true ]]; then
      printf 'Azure CLI %s returned status %d, but desired state was reached\n' "${operation}" "${mutation_rc}"
      rm -rf "${capture_dir}"
      return 0
    fi

    if [[ "${mutation_was_retryable}" != true ]]; then
      printf 'Azure CLI %s failed with non-retryable status %d\n' "${operation}" "${mutation_rc}" >&2
      rm -rf "${capture_dir}"
      return "${mutation_rc}"
    fi
    if ((attempt >= max_attempts)); then
      printf 'Azure CLI %s failed after %d reconciled attempts with status %d\n' "${operation}" "${max_attempts}" "${mutation_rc}" >&2
      rm -rf "${capture_dir}"
      return "${mutation_rc}"
    fi

    printf 'Azure CLI %s hit retryable status %d and desired state is not satisfied (attempt %d/%d); retrying in %ds\n' "${operation}" "${mutation_rc}" "${attempt}" "${max_attempts}" "${delay}" >&2
    if sleep "${delay}"; then
      :
    else
      mutation_rc=$?
      printf 'Azure CLI %s retry wait ended with status %d\n' "${operation}" "${mutation_rc}" >&2
      rm -rf "${capture_dir}"
      return "${mutation_rc}"
    fi
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    if ((delay > max_delay)); then
      delay="${max_delay}"
    fi
  done
}
# END AZURE CLI MUTATION RETRY HELPER

role_assignment_absent() {
  local object_id="${1}"
  local role="${2}"
  local scope="${3}"
  local assignments
  local rc

  if assignments="$(run_az_with_retry "role assignment lookup" az role assignment list --assignee "${object_id}" --role "${role}" --scope "${scope}" --query '[].id' -o tsv)"; then
    :
  else
    rc=$?
    return "${rc}"
  fi

  [[ -z "${assignments}" ]] && AZURE_CLI_DESIRED_STATE=true
  return 0
}

delete_role_assignments_once() {
  local object_id="${1}"
  local role="${2}"
  local scope="${3}"
  local assignment_ids_text
  local rc
  local assignment_ids=()

  if assignment_ids_text="$(run_az_with_retry "role assignment lookup" az role assignment list --assignee "${object_id}" --role "${role}" --scope "${scope}" --query '[].id' -o tsv)"; then
    :
  else
    rc=$?
    return "${rc}"
  fi
  if [[ -z "${assignment_ids_text}" ]]; then
    return 0
  fi

  mapfile -t assignment_ids <<<"${assignment_ids_text}"
  az role assignment delete --ids "${assignment_ids[@]}"
}

aks_cluster_absent() {
  local cluster="${1}"
  local resource_group="${2}"
  local resource_group_exists
  local state
  local rc

  if resource_group_exists="$(run_az_with_retry "AKS resource group lookup" az group exists --name "${resource_group}" --output tsv)"; then
    :
  else
    rc=$?
    return "${rc}"
  fi
  if [[ "${resource_group_exists}" == "false" ]]; then
    AZURE_CLI_DESIRED_STATE=true
    return 0
  fi

  if state="$(run_az_with_retry "AKS cluster lookup" az aks list --resource-group "${resource_group}" --query "[?name=='${cluster}'].provisioningState | [0]" -o tsv)"; then
    :
  else
    rc=$?
    return "${rc}"
  fi

  if [[ -z "${state}" ]]; then
    AZURE_CLI_DESIRED_STATE=true
    return 0
  fi
  if [[ "${state}" == "Deleting" ]]; then
    if run_az_with_retry "AKS deletion wait" az aks wait --deleted --name "${cluster}" --resource-group "${resource_group}" --interval 30 --timeout 1200; then
      AZURE_CLI_DESIRED_STATE=true
      return 0
    else
      rc=$?
      return "${rc}"
    fi
  fi
  return 0
}

vmss_rolling_upgrade_inactive() {
  local vmss_id="${1}"
  local status
  local rc

  if status="$(run_az_with_retry "VMSS rolling upgrade lookup" az vmss rolling-upgrade get-latest --ids "${vmss_id}" --query runningStatus.code -o tsv)"; then
    :
  else
    rc=$?
    return "${rc}"
  fi
  case "${status}" in
    Cancelled|Completed|Faulted)
      AZURE_CLI_DESIRED_STATE=true
      ;;
    RollingForward)
      ;;
    *)
      echo "Unexpected VMSS rolling upgrade status '${status}'; cancellation state is uncertain." >&2
      return 1
      ;;
  esac
  return 0
}

cancel_active_vmss_rolling_upgrades() {
  local cluster="${1}"
  local resource_group="${2}"
  local node_resource_group
  local vmss_ids_text
  local vmss_id
  local vmss_name
  local rolling_upgrade_status
  local cancelled=false
  local vmss_ids=()

  if node_resource_group="$(run_az_with_retry "AKS node resource group lookup" az aks show --name "${cluster}" --resource-group "${resource_group}" --query nodeResourceGroup -o tsv)"; then
    :
  else
    echo "Unable to discover the AKS node resource group; continuing with cluster deletion." >&2
    return 1
  fi
  if [[ -z "${node_resource_group}" ]]; then
    echo "AKS node resource group is unavailable; continuing with cluster deletion." >&2
    return 1
  fi

  if vmss_ids_text="$(run_az_with_retry "AKS VMSS lookup" az vmss list --resource-group "${node_resource_group}" --query '[].id' -o tsv)"; then
    :
  else
    echo "Unable to list AKS VM scale sets; continuing with cluster deletion." >&2
    return 1
  fi
  [[ -z "${vmss_ids_text}" ]] && return 1
  mapfile -t vmss_ids <<<"${vmss_ids_text}"

  for vmss_id in "${vmss_ids[@]}"; do
    vmss_name="${vmss_id##*/}"
    if rolling_upgrade_status="$(run_az_with_retry "VMSS rolling upgrade lookup" az vmss rolling-upgrade get-latest --ids "${vmss_id}" --query runningStatus.code -o tsv)"; then
      :
    else
      echo "Unable to inspect rolling upgrade status for ${vmss_name}; continuing." >&2
      continue
    fi
    [[ "${rolling_upgrade_status}" == "RollingForward" ]] || continue

    echo "Cancelling active rolling upgrade for AKS VM scale set ${vmss_name}."
    if run_az_mutation_with_reconcile \
      "VMSS rolling upgrade cancellation" \
      vmss_rolling_upgrade_inactive "${vmss_id}" -- \
      az vmss rolling-upgrade cancel --ids "${vmss_id}" --output none; then
      cancelled=true
    else
      echo "Unable to cancel rolling upgrade for ${vmss_name}; attempting cluster deletion." >&2
    fi
  done

  [[ "${cancelled}" == true ]]
}

delete_aks_cluster() {
  local cluster="${1}"
  local resource_group="${2}"

  run_az_mutation_with_reconcile \
    "AKS cluster deletion" \
    aks_cluster_absent "${cluster}" "${resource_group}" -- \
    az aks delete --name "${cluster}" --resource-group "${resource_group}" --yes
}

verify_shared_value() {
  local path="${1}"
  local expected="${2}"
  local description="${3}"
  local value

  if [[ -L "${path}" || ! -f "${path}" ]]; then
    echo "${description} metadata at ${path} is unavailable; using the deterministic name" >&2
    return 0
  fi
  value="$(<"${path}")"
  if [[ "${value}" != "${expected}" ]]; then
    echo "Ignoring unexpected ${description} metadata at ${path}; using the deterministic name" >&2
  fi
}

RESOURCE_NAME_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
CLUSTER="${RESOURCE_NAME_PREFIX}-aks-cluster"
RESOURCEGROUP="${RESOURCE_NAME_PREFIX}-aks-rg"
verify_shared_value "${SHARED_DIR}/aks-cluster-name" "${CLUSTER}" "AKS cluster name"
verify_shared_value "${SHARED_DIR}/resourcegroup_aks" "${RESOURCEGROUP}" "AKS resource group"

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
    AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

az --version
run_az_with_retry "login" az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

AKS_KV_SECRETS_PROVIDER_OBJECT_ID=""
if [[ -f "${SHARED_DIR}/kv-object-id" && ! -L "${SHARED_DIR}/kv-object-id" ]]; then
  SHARED_AKS_KV_SECRETS_PROVIDER_OBJECT_ID="$(<"${SHARED_DIR}/kv-object-id")"
  if LIVE_AKS_KV_SECRETS_PROVIDER_OBJECT_ID="$(run_az_with_retry "AKS Key Vault identity lookup" az aks show --name "${CLUSTER}" --resource-group "${RESOURCEGROUP}" --query addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -o tsv)" && \
    [[ -n "${SHARED_AKS_KV_SECRETS_PROVIDER_OBJECT_ID}" && "${SHARED_AKS_KV_SECRETS_PROVIDER_OBJECT_ID}" == "${LIVE_AKS_KV_SECRETS_PROVIDER_OBJECT_ID}" ]]; then
    AKS_KV_SECRETS_PROVIDER_OBJECT_ID="${LIVE_AKS_KV_SECRETS_PROVIDER_OBJECT_ID}"
  else
    echo "AKS Key Vault object ID metadata could not be verified; skipping role assignment cleanup."
  fi
fi

if [[ -n "${AKS_KV_SECRETS_PROVIDER_OBJECT_ID}" ]]; then
  AZURE_KEY_VAULT_INFO_LOCATION="/etc/hypershift-ci-jobs-azurecreds/keyvault-info.json"

  # Delete role assignments before deleting the cluster. Each retry re-lists
  # the assignment IDs so a lost successful response is reconciled.
  RESOURCE_GROUP_SCOPE="/subscriptions/${AZURE_AUTH_SUBSCRIPTION_ID}/resourceGroups/${RESOURCEGROUP}"
  run_az_mutation_with_reconcile \
    "role assignment deletion for RESOURCEGROUP" \
    role_assignment_absent "$AKS_KV_SECRETS_PROVIDER_OBJECT_ID" "Key Vault Secrets User" "$RESOURCE_GROUP_SCOPE" -- \
    delete_role_assignments_once "$AKS_KV_SECRETS_PROVIDER_OBJECT_ID" "Key Vault Secrets User" "$RESOURCE_GROUP_SCOPE"
  echo "Role assignment is absent for the RESOURCEGROUP."

  if [[ -f "${AZURE_KEY_VAULT_INFO_LOCATION}" && ! -L "${AZURE_KEY_VAULT_INFO_LOCATION}" ]] && \
    KV_RG_NAME="$(jq -er '.keyvaultRGName | select(type == "string" and length > 0)' "${AZURE_KEY_VAULT_INFO_LOCATION}" 2>/dev/null)"; then
    KV_RESOURCE_GROUP_SCOPE="/subscriptions/${AZURE_AUTH_SUBSCRIPTION_ID}/resourceGroups/${KV_RG_NAME}"
    run_az_mutation_with_reconcile \
      "role assignment deletion for KV_RG_NAME" \
      role_assignment_absent "$AKS_KV_SECRETS_PROVIDER_OBJECT_ID" "Key Vault Secrets User" "$KV_RESOURCE_GROUP_SCOPE" -- \
      delete_role_assignments_once "$AKS_KV_SECRETS_PROVIDER_OBJECT_ID" "Key Vault Secrets User" "$KV_RESOURCE_GROUP_SCOPE"
    echo "Role assignment is absent for the KV_RG_NAME."
  else
    echo "AKS Key Vault resource group metadata unavailable; skipping its role assignment cleanup."
  fi
fi

# Platform-initiated VM Agent rolling upgrades prevent Azure from deleting the
# underlying scale sets. Cancelling them is safe because this disposable
# management cluster is already being destroyed.
cancel_active_vmss_rolling_upgrades "${CLUSTER}" "${RESOURCEGROUP}" || true

# If an AKS delete response is lost, reconcile absence. A cluster already in
# Deleting state is waited on instead of issuing a competing delete request.
echo "Deleting AKS management cluster ${CLUSTER} from resource group ${RESOURCEGROUP}"
if delete_aks_cluster "${CLUSTER}" "${RESOURCEGROUP}"; then
  :
else
  DELETION_RC=$?
  if cancel_active_vmss_rolling_upgrades "${CLUSTER}" "${RESOURCEGROUP}"; then
    echo "Retrying AKS management cluster deletion after cancelling a rolling upgrade."
    delete_aks_cluster "${CLUSTER}" "${RESOURCEGROUP}"
  else
    exit "${DELETION_RC}"
  fi
fi
echo "Verifying AKS management cluster ${CLUSTER} is deleted from resource group ${RESOURCEGROUP}"
run_az_with_retry "AKS deletion verification" az aks wait --deleted --name "$CLUSTER" --resource-group "$RESOURCEGROUP" --interval 30 --timeout 1200
