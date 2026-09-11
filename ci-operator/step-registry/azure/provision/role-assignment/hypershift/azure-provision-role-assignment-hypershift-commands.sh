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

AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
AZURE_MANAGED_IDENTITIES_LOCATION="/etc/hypershift-ci-jobs-azurecreds/managed-identities.json"
AZURE_WORKLOAD_IDENTITIES_LOCATION="/etc/hypershift-ci-jobs-azurecreds/dataplane-identities.json"

# Load Azure credentials
AZURE_AUTH_CLIENT_ID="$(jq -r .clientId < "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_CLIENT_SECRET="$(jq -r .clientSecret < "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_SUBSCRIPTION_ID="$(jq -r .subscriptionId < "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_TENANT_ID="$(jq -r .tenantId < "${AZURE_AUTH_LOCATION}")"

az --version
az cloud set --name AzureCloud
run_az_with_retry "login" az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

RG_NSG=$(<"${SHARED_DIR}/resourcegroup_nsg")
RG_VNET=$(<"${SHARED_DIR}/resourcegroup_vnet")
RG_HC=$(<"${SHARED_DIR}/resourcegroup")

CONTROLPLANE_COMPONENTS=("disk" "file" "imageRegistry" "cloudProvider" "network" "controlPlaneOperator" "ingress" "nodePoolManagement")
DATAPLANE_COMPONENTS=("imageRegistryMSIClientID" "diskMSIClientID" "fileMSIClientID")

# Function to get client ID for a component
get_controlplane_object_id() {
  local component=$1
  local client_id
  client_id=$(jq -r ."$component".clientID < "${AZURE_MANAGED_IDENTITIES_LOCATION}")

  run_az_with_retry "service principal lookup" az ad sp show --id "$client_id" | jq -r .id
}

get_dataplane_object_id() {
  local component=$1
  local client_id
  client_id=$(jq -r ."$component" < "${AZURE_WORKLOAD_IDENTITIES_LOCATION}")

  run_az_with_retry "service principal lookup" az ad sp show --id "$client_id" | jq -r .id
}

# Assign roles
for component in "${CONTROLPLANE_COMPONENTS[@]}"; do
  object_id=$(get_controlplane_object_id "$component")
  if [[ -z "$object_id" ]]; then
    echo "Error: Missing objectID for component $component" >&2
    exit 1
  fi

  ROLE="b24988ac-6180-42a0-ab88-20f7382dd24c"
  scopes="/subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_HC"

  if [[ $component == "ingress" ]]; then
    ROLE="0336e1d3-7a87-462b-b6db-342b63f7802c"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$BASE_DOMAIN_RESOURCE_GROUP"
  fi

  if [[ $component == "cloudProvider" ]]; then
    ROLE="a1f96423-95ce-4224-ab27-4e3dc72facd4"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
  fi

  if [[ $component == "controlPlaneOperator" ]]; then
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
  fi

  if [[ $component == "nodePoolManagement" ]]; then
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
  fi

  if [[ $component == "disk" ]]; then
    ROLE="5b7237c5-45e1-49d6-bc18-a1f62f400748"
  fi

  if [[ $component == "file" ]]; then
    ROLE="0d7aedc0-15fd-4a67-a412-efad370c947e"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
    scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
  fi

  if [[ $component == "network" ]]; then
    ROLE="be7a6435-15ae-4171-8f30-4a343eff9e8f"
  fi

  if [[ $component == "imageRegistry" ]]; then
    ROLE="8b32b316-c2f5-4ddf-b05b-83dacd2d08b5"
  fi

  for scope in $scopes; do
    ensure_role_assignment "$object_id" "$ROLE" "$scope"
  done
done

for component in "${DATAPLANE_COMPONENTS[@]}"; do
  object_id=$(get_dataplane_object_id "$component")
  if [[ -z "$object_id" ]]; then
    echo "Error: Missing objectID for component $component" >&2
    exit 1
  fi

  scope="/subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_HC"

  if [[ $component == "imageRegistryMSIClientID" ]]; then
    ROLE="8b32b316-c2f5-4ddf-b05b-83dacd2d08b5"
  fi

  if [[ $component == "diskMSIClientID" ]]; then
    ROLE="5b7237c5-45e1-49d6-bc18-a1f62f400748"
  fi

  if [[ $component == "fileMSIClientID" ]]; then
    ROLE="0d7aedc0-15fd-4a67-a412-efad370c947e"
  fi

  ensure_role_assignment "$object_id" "$ROLE" "$scope"

done
