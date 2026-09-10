#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export AZURE_TOKEN_CREDENTIALS=prod

# The shared-leftovers workflow resolves orphaned role-assignment principals via
# Microsoft Graph, which requires directory read permissions (Directory.Read.All).
# The per-environment ARM identity above usually lacks that tenant-wide grant, so
# export a dedicated Graph identity from GRAPH_SECRET_PROFILE (the dev bot by
# default). When it resolves to the same profile as the ARM identity, skip it and
# let cleanup-sweeper fall back to a single identity for both ARM and Graph.
GRAPH_PROFILE_DIR="/var/run/aro-hcp-${GRAPH_SECRET_PROFILE}"
# Log which identity backs ARM versus Graph (no secrets: only profile paths and a
# yes/no) so a failed run makes it obvious whether the dedicated Graph identity was
# picked up or the ARM identity was used as fallback.
echo "cleanup-sweeper identity selection:"
echo "  ARM profile:   ${CLUSTER_PROFILE_DIR} (VAULT_SECRET_PROFILE=${VAULT_SECRET_PROFILE})"
echo "  Graph profile: ${GRAPH_PROFILE_DIR} (GRAPH_SECRET_PROFILE=${GRAPH_SECRET_PROFILE}) exists=$([[ -d "${GRAPH_PROFILE_DIR}" ]] && echo yes || echo no)"
if [[ -d "${GRAPH_PROFILE_DIR}" && "${GRAPH_PROFILE_DIR}" != "${CLUSTER_PROFILE_DIR}" ]]; then
  export GRAPH_AZURE_CLIENT_ID; GRAPH_AZURE_CLIENT_ID=$(cat "${GRAPH_PROFILE_DIR}/client-id")
  export GRAPH_AZURE_TENANT_ID; GRAPH_AZURE_TENANT_ID=$(cat "${GRAPH_PROFILE_DIR}/tenant")
  export GRAPH_AZURE_CLIENT_SECRET; GRAPH_AZURE_CLIENT_SECRET=$(cat "${GRAPH_PROFILE_DIR}/client-secret")
  echo "  using dedicated Graph identity for directory reads"
else
  echo "  using ARM identity for directory reads (no separate Graph profile)"
fi

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
