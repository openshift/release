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
      cat "${capture_dir}/stderr" >&2
      rm -rf "${capture_dir}"
      return 0
    else
      rc=$?
    fi

    # Do not allow partial output from a failed attempt to satisfy a caller's
    # command substitution. Preserve it as diagnostic output instead.
    cat "${capture_dir}/stdout" >&2
    cat "${capture_dir}/stderr" >&2

    if ((rc >= 128 && rc <= 192)); then
      rm -rf "${capture_dir}"
      return "${rc}"
    fi

    if ! grep -Eiq "${AZURE_CLI_TRANSIENT_ERROR_PATTERN}" "${capture_dir}/stderr"; then
      rm -rf "${capture_dir}"
      return "${rc}"
    fi

    if ((attempt >= max_attempts)); then
      echo "Azure CLI ${operation} failed after ${max_attempts} attempts due to transient transport errors" >&2
      rm -rf "${capture_dir}"
      return "${rc}"
    fi

    echo "Azure CLI ${operation} hit a transient transport error (attempt ${attempt}/${max_attempts}); retrying in ${delay}s" >&2
    if sleep "${delay}"; then
      :
    else
      rc=$?
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
      cat "${capture_dir}/stderr" >&2
      rm -rf "${capture_dir}"
      return 0
    else
      mutation_rc=$?
    fi

    cat "${capture_dir}/stdout" >&2
    cat "${capture_dir}/stderr" >&2

    if ((mutation_rc >= 128 && mutation_rc <= 192)); then
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
      echo "Azure CLI ${operation}: desired state was reached despite the command error"
      rm -rf "${capture_dir}"
      return 0
    fi

    if [[ "${mutation_was_retryable}" != true ]]; then
      rm -rf "${capture_dir}"
      return "${mutation_rc}"
    fi
    if ((attempt >= max_attempts)); then
      echo "Azure CLI ${operation} failed after ${max_attempts} reconciled attempts due to transient transport errors" >&2
      rm -rf "${capture_dir}"
      return "${mutation_rc}"
    fi

    echo "Azure CLI ${operation} hit a retryable or ambiguous error and desired state is not satisfied (attempt ${attempt}/${max_attempts}); retrying in ${delay}s" >&2
    if sleep "${delay}"; then
      :
    else
      mutation_rc=$?
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

# BEGIN AZURE ROLE ASSIGNMENT RECONCILIATION
role_assignment_exists() {
  local object_id="${1}"
  local role="${2}"
  local scope="${3}"
  local assignments
  local rc

  if assignments="$(run_az_with_retry "role assignment lookup" az role assignment list --assignee "${object_id}" --role "${role}" --scope "${scope}" -o tsv)"; then
    :
  else
    rc=$?
    return "${rc}"
  fi

  [[ -n "${assignments}" ]] && AZURE_CLI_DESIRED_STATE=true
  return 0
}

ensure_role_assignment() {
  local object_id="${1}"
  local role="${2}"
  local scope="${3}"
  local assignment_hash
  local assignment_name

  assignment_hash="$(printf '%s\0%s\0%s' "${object_id}" "${role}" "${scope}" | sha256sum)"
  assignment_hash="${assignment_hash%% *}"
  assignment_name="${assignment_hash:0:8}-${assignment_hash:8:4}-${assignment_hash:12:4}-${assignment_hash:16:4}-${assignment_hash:20:12}"

  run_az_mutation_with_reconcile \
    "role assignment creation" \
    role_assignment_exists "${object_id}" "${role}" "${scope}" -- \
    az role assignment create \
    --name "${assignment_name}" \
    --assignee-object-id "${object_id}" \
    --role "${role}" \
    --scope "${scope}" \
    --assignee-principal-type ServicePrincipal
}
# END AZURE ROLE ASSIGNMENT RECONCILIATION

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
  AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi

AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

az --version
az cloud set --name AzureCloud
run_az_with_retry "login" az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription "${AZURE_AUTH_SUBSCRIPTION_ID}"

AZURE_KEY_VAULT_INFO_LOCATION="/etc/hypershift-aro-azurecreds/keyvault-info.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
  AZURE_KEY_VAULT_INFO_LOCATION="/etc/hypershift-ci-jobs-azurecreds/keyvault-info.json"
fi
KV_NAME="$(<"${AZURE_KEY_VAULT_INFO_LOCATION}" jq -r .keyvaultName)"
KV_RG_NAME="$(<"${AZURE_KEY_VAULT_INFO_LOCATION}" jq -r .keyvaultRGName)"

set -x

RESOURCE_GROUP="$(<"${SHARED_DIR}/resourcegroup_aks")"
CLUSTER="$(<"${SHARED_DIR}/cluster-name")"

AZURE_KEY_VAULT_AUTHORIZED_OBJECT_ID=$(run_az_with_retry "AKS cluster lookup" az aks show -n "$CLUSTER" -g "$RESOURCE_GROUP" | jq .addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -r)

echo "Granting the AKS clusters azureKeyvaultSecretsProvider ServicePrincipal permissions to the KeyVault Resource Group"
ensure_role_assignment \
  "$AZURE_KEY_VAULT_AUTHORIZED_OBJECT_ID" \
  "Key Vault Secrets User" \
  "/subscriptions/${AZURE_AUTH_SUBSCRIPTION_ID}/resourceGroups/${KV_RG_NAME}"

echo "Granting ServicePrincipal permissions to the KeyVault"
SP_ID=$(run_az_with_retry "service principal lookup" az ad sp show --id "$AZURE_AUTH_CLIENT_ID" --query id -o tsv)
SCOPE=$(run_az_with_retry "Key Vault lookup" az keyvault show --name "$KV_NAME" -g "$KV_RG_NAME" --query id -o tsv)
ROLE="Key Vault Administrator"

ensure_role_assignment "$SP_ID" "$ROLE" "$SCOPE"
