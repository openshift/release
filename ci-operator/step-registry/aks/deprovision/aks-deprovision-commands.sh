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
  local state
  local rc

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

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
    AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

AZURE_KEY_VAULT_INFO_LOCATION="/etc/hypershift-ci-jobs-azurecreds/keyvault-info.json"
KV_RG_NAME="$(<"${AZURE_KEY_VAULT_INFO_LOCATION}" jq -r .keyvaultRGName)"

CLUSTER="$(<"${SHARED_DIR}/cluster-name")"
RESOURCEGROUP="$(<"${SHARED_DIR}/resourcegroup_aks")"
AKS_KV_SECRETS_PROVIDER_OBJECT_ID="$(<"${SHARED_DIR}/kv-object-id")"

az --version
run_az_with_retry "login" az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

# Delete role assignments before deleting the cluster. Each retry re-lists the
# assignment IDs so a response lost after a successful delete is reconciled.
RESOURCE_GROUP_SCOPE="/subscriptions/${AZURE_AUTH_SUBSCRIPTION_ID}/resourceGroups/${RESOURCEGROUP}"
run_az_mutation_with_reconcile \
  "role assignment deletion for RESOURCEGROUP" \
  role_assignment_absent "$AKS_KV_SECRETS_PROVIDER_OBJECT_ID" "Key Vault Secrets User" "$RESOURCE_GROUP_SCOPE" -- \
  delete_role_assignments_once "$AKS_KV_SECRETS_PROVIDER_OBJECT_ID" "Key Vault Secrets User" "$RESOURCE_GROUP_SCOPE"
echo "Role assignment is absent for the RESOURCEGROUP."

KV_RESOURCE_GROUP_SCOPE="/subscriptions/${AZURE_AUTH_SUBSCRIPTION_ID}/resourceGroups/${KV_RG_NAME}"
run_az_mutation_with_reconcile \
  "role assignment deletion for KV_RG_NAME" \
  role_assignment_absent "$AKS_KV_SECRETS_PROVIDER_OBJECT_ID" "Key Vault Secrets User" "$KV_RESOURCE_GROUP_SCOPE" -- \
  delete_role_assignments_once "$AKS_KV_SECRETS_PROVIDER_OBJECT_ID" "Key Vault Secrets User" "$KV_RESOURCE_GROUP_SCOPE"
echo "Role assignment is absent for the KV_RG_NAME."

# If an AKS delete response is lost, reconcile absence. A cluster already in
# Deleting state is waited on instead of issuing a competing delete request.
run_az_mutation_with_reconcile \
  "AKS cluster deletion" \
  aks_cluster_absent "$CLUSTER" "$RESOURCEGROUP" -- \
  az aks delete --name "$CLUSTER" --resource-group "$RESOURCEGROUP" --yes
