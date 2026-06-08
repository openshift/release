#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

slot_manager_args=(
    --deploy-env "${ARO_HCP_DEPLOY_ENV}"
    --shared-dir "${SHARED_DIR}"
)

if [[ -n "${ALLOWED_SUBSCRIPTIONS:-}" ]]; then
    slot_manager_args+=(--allowed-subscriptions "${ALLOWED_SUBSCRIPTIONS}")
fi

if [[ -n "${ALLOWED_LOCATIONS:-}" ]]; then
    slot_manager_args+=(--allowed-locations "${ALLOWED_LOCATIONS}")
fi

if [[ -n "${ARO_HCP_SLOT_MANAGER_MAX_WAIT_FOR_LEASE:-}" ]]; then
    slot_manager_args+=(--max-wait-for-lease "${ARO_HCP_SLOT_MANAGER_MAX_WAIT_FOR_LEASE}")
fi

if [[ -n "${ARO_HCP_SLOT_MANAGER_LEASE_WAIT_INTERVAL:-}" ]]; then
    slot_manager_args+=(--lease-wait-interval "${ARO_HCP_SLOT_MANAGER_LEASE_WAIT_INTERVAL}")
fi

./test/aro-hcp-tests slot-manager acquire "${slot_manager_args[@]}"
