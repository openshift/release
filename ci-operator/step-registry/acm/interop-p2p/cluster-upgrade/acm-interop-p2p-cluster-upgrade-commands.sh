#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Export environment variables
#=====================
export TARGET_CHANNEL

#=====================
# Configuration variables
#=====================
typeset -i timeoutSeconds="${ACM_UPGRADE_TIMEOUT_SECONDS:-7200}"
typeset -i pollInterval="${ACM_UPGRADE_POLL_INTERVAL:-30}"

#=====================
# Validate required files and variables
#=====================
if [[ -z "${ORIGINAL_RELEASE_IMAGE_LATEST:-}" ]]; then
    : "[ERROR] ORIGINAL_RELEASE_IMAGE_LATEST environment variable is not set" >&2
    exit 1
fi

[ -f "${SHARED_DIR}/kubeconfig" ] || {
    : "[ERROR] Hub kubeconfig not found: ${SHARED_DIR}/kubeconfig" >&2
    exit 1
}

[ -f "${SHARED_DIR}/managed-cluster-kubeconfig" ] || {
    : "[ERROR] Spoke kubeconfig not found: ${SHARED_DIR}/managed-cluster-kubeconfig" >&2
    exit 1
}

#=====================
# Helper functions
#=====================
Need() {
    command -v "$1" 1>/dev/null || {
        : "[FATAL] '$1' not found" >&2
        exit 1
    }
}

Now() {
    date +%s
}

Need oc
Need jq

#=====================
# Resolve target version and digest
#=====================
# Query release controller for latest RC metadata
typeset targetVersion
targetVersion="$(oc adm release info "${ORIGINAL_RELEASE_IMAGE_LATEST}" -o json | jq -r '.metadata.version')"

if [[ -z "${targetVersion}" ]]; then
    : "[ERROR] Failed to get target version from release image" >&2
    exit 1
fi

# Digest is required to safely upgrade the cluster using release image
typeset digest
digest="$(oc adm release info "${ORIGINAL_RELEASE_IMAGE_LATEST}" -o json | jq -r .digest)"

if [[ -z "${digest}" ]]; then
    : "[ERROR] Failed to get digest from release image" >&2
    exit 1
fi

: "Target version: ${targetVersion}"
: "Target digest: ${digest}"

#=====================
# Kubeconfig paths
#=====================
typeset hubKubeconfig="${SHARED_DIR}/kubeconfig"
typeset spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"

#=====================
# Upgrade functions
#=====================
UpgradeCluster() {
    typeset kfcg="$1"
    typeset ctx="$2"
    typeset repo

    : "Upgrading ${ctx} to channel=${TARGET_CHANNEL} version=${targetVersion}"

    oc --kubeconfig="${kfcg}" patch clusterversion version --type merge \
        -p "{\"spec\":{\"channel\":\"${TARGET_CHANNEL}\"}}"

    repo="${ORIGINAL_RELEASE_IMAGE_LATEST%:*}"
    : "Repository: ${repo}"

    oc --kubeconfig="${kfcg}" adm upgrade \
        --to-image="${repo}@${digest}" \
        --allow-explicit-upgrade \
        --allow-upgrade-with-warnings \
        --force

    true
}

WaitForCompleted() {
    typeset kfcg="$1"
    typeset ctx="$2"
    typeset target="$3"
    typeset -i start
    typeset state
    typeset ver
    typeset clusterversionJson

    start="$(Now)"
    : "Waiting for ${ctx} to complete upgrade to ${target}"

    while true; do
        clusterversionJson="$(oc --kubeconfig="${kfcg}" get clusterversion version -o json || echo '{}')"
        state="$(jq -r '.status.history[0].state // empty' <<<"${clusterversionJson}")"
        ver="$(jq -r '.status.history[0].version // empty' <<<"${clusterversionJson}")"

        if [[ "${state}" == "Completed" && "${ver}" == "${target}" ]]; then
            : "${ctx}: Upgrade completed to version ${ver}"
            break
        fi

        if (( $(Now) - start > timeoutSeconds )); then
            : "[ERROR] Timeout waiting for ${ctx} (state='${state:-?}' version='${ver:-?}' target='${target}')" >&2
            exit 2
        fi

        : "${ctx}: state='${state:-?}', version='${ver:-?}', retry in ${pollInterval}s"
        sleep "${pollInterval}"
    done

    true
}

#=====================
# Execute upgrades
#=====================
# Hub upgrade
UpgradeCluster "${hubKubeconfig}" "hub"
WaitForCompleted "${hubKubeconfig}" "hub" "${targetVersion}"

# Spoke upgrade
UpgradeCluster "${spokeKubeconfig}" "spoke"
WaitForCompleted "${spokeKubeconfig}" "spoke" "${targetVersion}"

# Check cluster health for hub and spoke clusters after upgrade

true
