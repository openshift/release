#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export AZURE_TOKEN_CREDENTIALS=prod

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none

go build -o /tmp/cleanup-sweeper ./tooling/cleanup-sweeper

discover_subscription_ids() {
  local -a ids=()
  local file sub_id

  # infra-*-subscription-id matches all infra subscriptions including
  # infra-global-subscription-id (global shared infra: ACR, Kusto, KV, DNS)
  # and infra-shardN-subscription-id (per-shard infra).
  # customer-*-subscription-id matches all customer/hosted-cluster subscriptions.
  for file in "${CLUSTER_PROFILE_DIR}"/customer-*-subscription-id \
              "${CLUSTER_PROFILE_DIR}"/infra-*-subscription-id; do
    [[ -f "${file}" ]] || continue
    sub_id="$(cat "${file}")"
    if [[ -n "${sub_id}" ]]; then
      ids+=("${sub_id}")
    fi
  done

  if [[ "${#ids[@]}" -eq 0 ]]; then
    echo "No subscription IDs discovered in ${CLUSTER_PROFILE_DIR}" >&2
    return 1
  fi

  printf '%s\n' "${ids[@]}"
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
    read -r -a extra_args <<< "${CLEANUP_SWEEPER_EXTRA_ARGS}"
    cmd+=("${extra_args[@]}")
  fi

  printf 'Running:'
  printf ' %q' "${cmd[@]}"
  printf '\n'
  "${cmd[@]}"
}

mapfile -t subscription_ids < <(discover_subscription_ids | sort -u)
echo "Discovered ${#subscription_ids[@]} unique subscription(s)"

failures=0
for sub_id in "${subscription_ids[@]}"; do
  echo "Starting cleanup for subscription id='${sub_id}'"
  if ! run_cleanup "${sub_id}"; then
    failures=$((failures + 1))
    echo "Cleanup failed for subscription id='${sub_id}'; continuing"
  fi
done

if [[ "${failures}" -gt 0 ]]; then
  echo "Cleanup failed for ${failures} of ${#subscription_ids[@]} subscription(s)"
  exit 1
fi
