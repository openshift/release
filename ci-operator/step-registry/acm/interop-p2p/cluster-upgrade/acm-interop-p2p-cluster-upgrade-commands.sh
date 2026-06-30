#!/bin/bash
#
# Upgrades hub and spoke clusters to the release image in OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE
# (sourced from release:latest via the ref dependency).
# Patches ACM_CLUSTER_UPGRADE_TARGET_CHANNEL when set, admin-ack from Upgradeable condition, then initiates
# and waits for clusterversion upgrade to complete. Hub is upgraded first, then spoke.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

[[ -n "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" ]]
[ -f "${SHARED_DIR}/kubeconfig" ]
[ -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]

typeset targetVersion=''
typeset digest=''

WriteUpgradeFailureDiagnostics() {
    typeset kubeconfig="${1:?}"
    typeset ctx="${2:-cluster}"
    typeset artifactFile="${ARTIFACT_DIR}/${ctx}-upgrade-failure.txt"

    {
        printf '%s\n' "=== targetVersion=${targetVersion:-unknown} ==="
        printf '\n'
        printf '%s\n' "=== oc get clusterversion version ==="
        oc --kubeconfig="${kubeconfig}" get clusterversion version -o wide 2>&1 || true
        printf '\n'
        printf '%s\n' "=== oc describe clusterversion version ==="
        oc --kubeconfig="${kubeconfig}" describe clusterversion version 2>&1 || true
        printf '\n'
        printf '%s\n' "=== oc get events -A (last 40) ==="
        oc --kubeconfig="${kubeconfig}" get events -A --sort-by='.lastTimestamp' 2>&1 | tail -40 || true
    } > "${artifactFile}"
    : "Wrote upgrade failure diagnostics to ${artifactFile}"
    true
}

# Patch admin-ack ConfigMap when the Upgradeable condition requires it.
PatchAdminAcksForUpgrade() {
    typeset kubeconfig="${1:?}"
    typeset upgradeableMsg='' ackKey=''

    upgradeableMsg="$(oc --kubeconfig="${kubeconfig}" get clusterversion version \
        -o jsonpath='{.status.conditions[?(@.type=="Upgradeable")].message}' || true)"
    if [[ -n "${upgradeableMsg}" ]]; then
        ackKey="$(grep -oE 'ack-[a-zA-Z0-9.-]+' <<< "${upgradeableMsg}" | head -1 || true)"
    fi
    if [[ -n "${ackKey}" ]]; then
        : "Patching admin-ack '${ackKey}' from Upgradeable condition"
        oc --kubeconfig="${kubeconfig}" patch configmap admin-acks-upgrades -n openshift-config \
            --type merge \
            -p "$(jq -cn --arg k "${ackKey}" '{data: {($k): "true"}}')" \
            || : "admin-acks-upgrades patch skipped (ConfigMap may not exist on this cluster)"
    else
        : "No admin-ack key in Upgradeable condition; skipping patch"
    fi
    true
}

UpgradeCluster() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset ctx="${1:?}"; (($#)) && shift

    : "Upgrading ${ctx} to version=${targetVersion} channel=${ACM_CLUSTER_UPGRADE_TARGET_CHANNEL:-<unchanged>}"

    if [[ -n "${ACM_CLUSTER_UPGRADE_TARGET_CHANNEL}" ]]; then
        oc --kubeconfig="${kubeconfig}" patch clusterversion version \
            --type merge \
            -p "$(jq -cn --arg ch "${ACM_CLUSTER_UPGRADE_TARGET_CHANNEL}" '{"spec":{"channel":$ch}}')"
    fi

    PatchAdminAcksForUpgrade "${kubeconfig}"

    # Strip tag or digest suffix to get bare registry/repo, then re-pin by digest.
    typeset repo="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE%:*}"
    repo="${repo%@sha256*}"

    oc --kubeconfig="${kubeconfig}" adm upgrade \
        --to-image="${repo}@${digest}" \
        --allow-explicit-upgrade \
        --allow-upgrade-with-warnings \
        --force
    true
}

# Two oc wait calls are needed because oc wait supports only one jsonpath condition each.
# The first wait guards against a race: immediately after oc adm upgrade, history[0] still
# reflects the previous upgrade's Completed state. Only once history[0].version matches
# targetVersion is it safe to poll for Completed.
WaitForCompleted() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset ctx="${1:?}"; (($#)) && shift

    : "Waiting for ${ctx} to reach version=${targetVersion} (timeout=${ACM_UPGRADE_TIMEOUT})"

    oc --kubeconfig="${kubeconfig}" wait clusterversion/version \
        --for=jsonpath='{.status.history[0].version}'="${targetVersion}" \
        --timeout="${ACM_UPGRADE_TIMEOUT}" || {
        WriteUpgradeFailureDiagnostics "${kubeconfig}" "${ctx}"
        false
    }

    oc --kubeconfig="${kubeconfig}" wait clusterversion/version \
        --for=jsonpath='{.status.history[0].state}'="Completed" \
        --timeout="${ACM_UPGRADE_TIMEOUT}" || {
        WriteUpgradeFailureDiagnostics "${kubeconfig}" "${ctx}"
        false
    }

    : "${ctx} upgrade to ${targetVersion} completed"
    true
}

#=====================
# Resolve target version and digest from release image
#=====================
: "Resolving target version and digest from ${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
typeset releaseInfoJson
releaseInfoJson="$(oc adm release info "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" -o json)"

targetVersion="$(jq -r '.metadata.version' <<< "${releaseInfoJson}")"
[[ -n "${targetVersion}" ]]

digest="$(jq -r '.digest' <<< "${releaseInfoJson}")"
[[ -n "${digest}" ]]

: "Target version: ${targetVersion}  digest: ${digest}"

#=====================
# Kubeconfig paths
#=====================
typeset hubKubeconfig="${SHARED_DIR}/kubeconfig"
typeset spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"

#=====================
# Execute upgrades — hub then spoke
#=====================
: "Starting hub cluster upgrade"
UpgradeCluster "${hubKubeconfig}" "hub"
WaitForCompleted "${hubKubeconfig}" "hub"

: "Starting spoke cluster upgrade"
UpgradeCluster "${spokeKubeconfig}" "spoke"
WaitForCompleted "${spokeKubeconfig}" "spoke"

: "All clusters upgraded to ${targetVersion}"
true
