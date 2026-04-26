#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export SUBSCRIPTION_ID; SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/subscription-id")
export AZURE_TOKEN_CREDENTIALS=prod

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${SUBSCRIPTION_ID}"

go build -o /tmp/cleanup-sweeper ./tooling/cleanup-sweeper

trim_whitespace() {
  local value="${1}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

available_subscriptions=()

load_enabled_subscriptions() {
  mapfile -t available_subscriptions < <(az account list --all --query "[?state=='Enabled'].[name,id]" -o tsv)
  if [[ "${#available_subscriptions[@]}" -eq 0 ]]; then
    echo "No enabled subscriptions discovered in tenant ${AZURE_TENANT_ID}" >&2
    return 1
  fi
}

resolve_subscription_id() {
  local wanted_name="${1}"
  local entry subscription_name subscription_id

  for entry in "${available_subscriptions[@]}"; do
    IFS=$'\t' read -r subscription_name subscription_id <<< "${entry}"
    if [[ "${subscription_name}" == "${wanted_name}" ]]; then
      printf '%s\n' "${subscription_id}"
      return 0
    fi
  done

  echo "Configured subscription name '${wanted_name}' was not found among enabled subscriptions visible to this credential" >&2
  return 1
}

run_cleanup() {
  local subscription_id="${1}"
  local cmd=(
    /tmp/cleanup-sweeper
    --workflow "${CLEANUP_SWEEPER_WORKFLOW}"
    --subscription-id "${subscription_id}"
  )

  if [[ -n "${CLEANUP_SWEEPER_POLICY}" ]]; then
    cmd+=(--policy "${CLEANUP_SWEEPER_POLICY}")
  fi

  if [[ -n "${CLEANUP_SWEEPER_PARALLELISM}" ]]; then
    cmd+=(--parallelism "${CLEANUP_SWEEPER_PARALLELISM}")
  fi

  if [[ -n "${CLEANUP_SWEEPER_WAIT}" ]]; then
    cmd+=(--wait="${CLEANUP_SWEEPER_WAIT}")
  fi

  if [[ -n "${CLEANUP_SWEEPER_VERBOSITY}" ]]; then
    cmd+=(--verbosity="${CLEANUP_SWEEPER_VERBOSITY}")
  fi

  if [[ -n "${CLEANUP_SWEEPER_EXTRA_ARGS}" ]]; then
    # Intentional word splitting to support multiple CLI flags.
    read -r -a extra_args <<< "${CLEANUP_SWEEPER_EXTRA_ARGS}"
    cmd+=("${extra_args[@]}")
  fi

  printf 'Running:'
  printf ' %q' "${cmd[@]}"
  printf '\n'
  "${cmd[@]}"
}

run_named_subscription_cleanups() {
  local raw_name subscription_name subscription_id
  local failures=0
  local selected=0
  local -a requested_names=()

  IFS=',' read -r -a requested_names <<< "${CLEANUP_SWEEPER_SUBSCRIPTION_NAMES}"
  load_enabled_subscriptions

  for raw_name in "${requested_names[@]}"; do
    subscription_name="$(trim_whitespace "${raw_name}")"
    if [[ -z "${subscription_name}" ]]; then
      continue
    fi
    selected=$((selected + 1))
    subscription_id="$(resolve_subscription_id "${subscription_name}")"
    echo "Starting cleanup for subscription name='${subscription_name}' id='${subscription_id}'"
    if ! run_cleanup "${subscription_id}"; then
      failures=$((failures + 1))
      echo "Cleanup failed for subscription name='${subscription_name}' id='${subscription_id}'; continuing"
    fi
  done

  if [[ "${selected}" -eq 0 ]]; then
    echo "CLEANUP_SWEEPER_SUBSCRIPTION_NAMES was set but did not contain any subscription names" >&2
    return 1
  fi

  if [[ "${failures}" -gt 0 ]]; then
    echo "Cleanup failed for ${failures} subscription(s)"
    return 1
  fi

  return 0
}

if [[ -n "${CLEANUP_SWEEPER_SUBSCRIPTION_NAMES}" ]]; then
  run_named_subscription_cleanups
  exit 0
fi

current_subscription_id="$(az account show --query id -o tsv)"
run_cleanup "${current_subscription_id}"
