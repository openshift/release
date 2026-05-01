#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Export environment variables
#=====================
export TARGET_CHANNEL

#=====================
# Configuration variables
#=====================
timeout_seconds="${ACM_UPGRADE_TIMEOUT_SECONDS:-7200}"  # Default: 2 hours
poll_interval="${ACM_UPGRADE_POLL_INTERVAL:-30}"       # Default: 30 seconds

#=====================
# Validate required files and variables
#=====================
if [[ -z "${ORIGINAL_RELEASE_IMAGE_LATEST:-}" ]]; then
    echo "[ERROR] ORIGINAL_RELEASE_IMAGE_LATEST environment variable is not set" >&2
    exit 1
fi

if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
    echo "[ERROR] Hub kubeconfig not found: ${SHARED_DIR}/kubeconfig" >&2
    exit 1
fi

if [[ ! -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
    echo "[ERROR] Spoke kubeconfig not found: ${SHARED_DIR}/managed-cluster-kubeconfig" >&2
    exit 1
fi

#=====================
# Helper functions
#=====================
need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[FATAL] '$1' not found" >&2
        exit 1
    }
}

now() {
    date +%s
}

need oc
need jq

#=====================
# Resolve target version and digest
#=====================
echo "[INFO] Resolving latest RC's from release Controller..."
target_version="$(oc adm release info "${ORIGINAL_RELEASE_IMAGE_LATEST}" -o json | jq -r '.metadata.version')"

if [[ -z "${target_version}" ]]; then
    echo "[ERROR] Failed to get target version from release image" >&2
    exit 1
fi

# Get image digest, digest is required to safely upgrade the cluster using release image
digest="$(oc adm release info "${ORIGINAL_RELEASE_IMAGE_LATEST}" -o json | jq -r .digest)"

if [[ -z "${digest}" ]]; then
    echo "[ERROR] Failed to get digest from release image" >&2
    exit 1
fi

echo "[INFO] Target version: ${target_version}"
echo "[INFO] Target digest: ${digest}"

#=====================
# Set kubeconfig paths
#=====================
hub_kubeconfig="${SHARED_DIR}/kubeconfig"
spoke_kubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"

#=====================
# Upgrade functions
#=====================
upgrade_cluster() {
    local kfcg="$1"
    local ctx="$2"
    local repo

    echo "[INFO] Upgrading ${ctx} to channel=${TARGET_CHANNEL} and version=${target_version}"
    echo "[INFO] Target image: ${ORIGINAL_RELEASE_IMAGE_LATEST}"
    
    # Update channel
    oc --kubeconfig="${kfcg}" patch clusterversion version --type merge -p "{\"spec\":{\"channel\":\"${TARGET_CHANNEL}\"}}"
    
    # Extract repository from image reference
    repo="${ORIGINAL_RELEASE_IMAGE_LATEST%:*}"
    echo "[INFO] Repository: ${repo}"
    
    # Initiate upgrade
    oc --kubeconfig="${kfcg}" adm upgrade --to-image="${repo}@${digest}" --allow-explicit-upgrade --allow-upgrade-with-warnings --force
}

wait_for_completed() {
    local kfcg="$1"
    local ctx="$2"
    local target="$3"
    local start
    local state
    local ver

    start="$(now)"
    echo "[INFO] Waiting for ${ctx} to complete upgrade to ${target}"
    
    while true; do
        # Query clusterversion and get state and version
        clusterversion_json="$(oc --kubeconfig="${kfcg}" get clusterversion version -o json 2>/dev/null || echo '{}')"
        state="$(jq -r '.status.history[0].state // empty' <<<"${clusterversion_json}")"
        ver="$(jq -r '.status.history[0].version // empty' <<<"${clusterversion_json}")"
        
        # If state is completed and ver is target version then upgrade finished
        if [[ "${state}" == "Completed" && "${ver}" == "${target}" ]]; then
            echo "[SUCCESS] ${ctx}: Upgrade completed to version ${ver}"
            break
        fi
        
        # If version and state did not reach desired values before timeout then exit
        if (( $(now) - start > timeout_seconds )); then
            echo "[ERROR] Timeout waiting for ${ctx} (state='${state:-?}' version='${ver:-?}' target='${target}')" >&2
            exit 2
        fi
        
        echo "[INFO] ${ctx}: state='${state:-?}', version='${ver:-?}', retry in ${poll_interval}s"
        sleep "${poll_interval}"
    done
}

#=====================
# Execute upgrades
#=====================
# Hub upgrade
echo "[INFO] Starting hub cluster upgrade"
upgrade_cluster "${hub_kubeconfig}" "hub"
wait_for_completed "${hub_kubeconfig}" "hub" "${target_version}"

# Spoke upgrade
echo "[INFO] Starting spoke cluster upgrade"
upgrade_cluster "${spoke_kubeconfig}" "spoke"
wait_for_completed "${spoke_kubeconfig}" "spoke" "${target_version}"

echo "[SUCCESS] All selected clusters are at latest RCs"
# Check cluster health for hub and spoke clusters after upgrade
