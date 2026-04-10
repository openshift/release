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

if [[ "${CLEANUP_SWEEPER_ALL_SUBSCRIPTIONS}" == "true" ]]; then
  mapfile -t subscriptions < <(az account list --all --query "[?state=='Enabled'].[name,id]" -o tsv)
  if [[ "${#subscriptions[@]}" -eq 0 ]]; then
    echo "No enabled subscriptions discovered in tenant ${AZURE_TENANT_ID}"
    exit 1
  fi

  failures=0
  for subscription in "${subscriptions[@]}"; do
    IFS=$'\t' read -r subscription_name subscription_id <<< "${subscription}"
    echo "Starting cleanup for subscription name='${subscription_name}' id='${subscription_id}'"
    if ! run_cleanup "${subscription_id}"; then
      failures=$((failures + 1))
      echo "Cleanup failed for subscription name='${subscription_name}' id='${subscription_id}'; continuing"
    fi
  done

  if [[ "${failures}" -gt 0 ]]; then
    echo "Cleanup failed for ${failures} subscription(s)"
    exit 1
  fi

  exit 0
fi

current_subscription_id="$(az account show --query id -o tsv)"
run_cleanup "${current_subscription_id}"
