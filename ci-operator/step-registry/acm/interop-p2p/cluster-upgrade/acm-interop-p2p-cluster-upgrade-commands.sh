#!/bin/bash
#
# Upgrades the hub cluster to the latest RC image resolved from ORIGINAL_RELEASE_IMAGE_LATEST.
# Patches TARGET_CHANNEL, then initiates and waits for the clusterversion upgrade to complete.
#
set -euxo pipefail; shopt -s inherit_errexit

[[ -z "${ORIGINAL_RELEASE_IMAGE_LATEST:-}" ]] && {
    echo "[ERROR] ORIGINAL_RELEASE_IMAGE_LATEST is not set" >&2; exit 1
}
[[ ! -f "${SHARED_DIR}/kubeconfig" ]] && {
    echo "[ERROR] Hub kubeconfig not found: ${SHARED_DIR}/kubeconfig" >&2; exit 1
}

# Resolve version and digest once; shared by all UpgradeCluster calls.
typeset targetVersion
targetVersion="$(oc adm release info "${ORIGINAL_RELEASE_IMAGE_LATEST}" -o json | jq -r '.metadata.version')"
[[ -z "${targetVersion}" ]] && { echo "[ERROR] Failed to get target version from release image" >&2; exit 1; }

typeset digest
digest="$(oc adm release info "${ORIGINAL_RELEASE_IMAGE_LATEST}" -o json | jq -r '.digest')"
[[ -z "${digest}" ]] && { echo "[ERROR] Failed to get digest from release image" >&2; exit 1; }

echo "[INFO] Target version: ${targetVersion}  digest: ${digest}"

typeset hubKubeconfig="${SHARED_DIR}/kubeconfig"

# UpgradeCluster - Patches channel and initiates the upgrade on the given cluster.
# $1=kubeconfig path  $2=context label for logging (e.g. "hub", "spoke-1")
UpgradeCluster() {
    typeset kubeconfig="${1}"; (($#)) && shift
    typeset clusterCtx="${1}"; (($#)) && shift
    typeset imgRepo="${ORIGINAL_RELEASE_IMAGE_LATEST%:*}"

    echo "[INFO] Upgrading ${clusterCtx}: channel=${TARGET_CHANNEL} image=${imgRepo}@${digest}"

    # Use jq for JSON marshalling to avoid manual shell escaping.
    oc --kubeconfig="${kubeconfig}" patch clusterversion version --type merge \
        -p "$(jq -cn --arg ch "${TARGET_CHANNEL}" '{"spec":{"channel":$ch}}')"

    oc --kubeconfig="${kubeconfig}" adm upgrade \
        --to-image="${imgRepo}@${digest}" \
        --allow-explicit-upgrade \
        --allow-upgrade-with-warnings \
        --force
    true
}

# WaitForCompleted - Polls clusterversion until state=Completed at targetVersion, or timeout.
# $1=kubeconfig path  $2=context label  $3=target version string
WaitForCompleted() {
    typeset kubeconfig="${1}"; (($#)) && shift
    typeset clusterCtx="${1}"; (($#)) && shift
    typeset target="${1}"; (($#)) && shift
    typeset -i startSec
    startSec="$(date +%s)"
    typeset cvJson=''
    typeset state=''
    typeset ver=''

    echo "[INFO] Waiting for ${clusterCtx} to reach version ${target} (timeout=${ACM_UPGRADE_TIMEOUT_SECONDS}s)"

    while true; do
        cvJson="$(oc --kubeconfig="${kubeconfig}" get clusterversion version -o json 2>/dev/null || echo '{}')"
        state="$(jq -r '.status.history[0].state // empty' <<<"${cvJson}")"
        ver="$(jq -r '.status.history[0].version // empty' <<<"${cvJson}")"

        if [[ "${state}" == "Completed" && "${ver}" == "${target}" ]]; then
            echo "[SUCCESS] ${clusterCtx}: Upgrade completed to version ${ver}"
            break
        fi

        if (( $(date +%s) - startSec > ACM_UPGRADE_TIMEOUT_SECONDS )); then
            echo "[ERROR] Timeout waiting for ${clusterCtx} (state='${state:-?}' version='${ver:-?}' target='${target}')" >&2
            exit 2
        fi

        echo "[INFO] ${clusterCtx}: state='${state:-?}' version='${ver:-?}', retry in ${ACM_UPGRADE_POLL_INTERVAL}s"
        sleep "${ACM_UPGRADE_POLL_INTERVAL}"
    done
    true
}

UpgradeCluster "${hubKubeconfig}" "hub"
WaitForCompleted "${hubKubeconfig}" "hub" "${targetVersion}"

echo "[SUCCESS] Hub cluster is at latest RC: ${targetVersion}"
# Cluster health check runs in the next step (cucushift-installer-check-cluster-health).
true
