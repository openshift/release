#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

slot_manager_args=(
    --deploy-env "${ARO_HCP_DEPLOY_ENV}"
    --shared-dir "${SHARED_DIR}"
)

if [[ -n "${CLUSTER_PROFILE_DIRS:-}" ]]; then
    slot_manager_args+=(--cluster-profile-dirs "${CLUSTER_PROFILE_DIRS}")
fi

effective_allowed_subscriptions="${MULTISTAGE_PARAM_OVERRIDE_ALLOWED_SUBSCRIPTIONS:-${ALLOWED_SUBSCRIPTIONS:-}}"
if [[ -n "${effective_allowed_subscriptions}" ]]; then
    slot_manager_args+=(--allowed-subscriptions "${effective_allowed_subscriptions}")
fi

if [[ -n "${ALLOWED_LOCATIONS:-}" ]]; then
    slot_manager_args+=(--allowed-locations "${ALLOWED_LOCATIONS}")
fi

if [[ -n "${LOCATION_WEIGHTS:-}" ]]; then
    slot_manager_args+=(--location-weights "${LOCATION_WEIGHTS}")
fi

if [[ -n "${BUILD_ID:-}" ]]; then
    slot_manager_args+=(--build-id "${BUILD_ID}")
fi

# Highest-precedence region pin for runtime-selected pools; slot-manager acquire
# reads MULTISTAGE_PARAM_OVERRIDE_LOCATION from the environment.
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_LOCATION:-}" ]]; then
    export MULTISTAGE_PARAM_OVERRIDE_LOCATION="${MULTISTAGE_PARAM_OVERRIDE_LOCATION}"
fi

if [[ -n "${ARO_HCP_SLOT_MANAGER_MAX_WAIT_FOR_LEASE:-}" ]]; then
    slot_manager_args+=(--max-wait-for-lease "${ARO_HCP_SLOT_MANAGER_MAX_WAIT_FOR_LEASE}")
fi

if [[ -n "${ARO_HCP_SLOT_MANAGER_LEASE_WAIT_INTERVAL:-}" ]]; then
    slot_manager_args+=(--lease-wait-interval "${ARO_HCP_SLOT_MANAGER_LEASE_WAIT_INTERVAL}")
fi

./test/aro-hcp-tests slot-manager acquire "${slot_manager_args[@]}"
