#!/bin/bash
#
# Upgrades the hub cluster to the release image in OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE
# (sourced from release:target via the ref dependency).
# Patches ACM_CLUSTER_UPGRADE_TARGET_CHANNEL when set, admin-ack from Upgradeable condition, then initiates
# and waits for clusterversion upgrade to complete.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

[[ -n "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" ]]

typeset targetVersion=''
typeset digest=''

WriteUpgradeFailureDiagnostics() {
    typeset ctx="${1:-cluster}"
    typeset artifactFile="${ARTIFACT_DIR}/${ctx}-upgrade-failure.txt"

    # All commands below use || true: this function is already on the failure path.
    # A secondary failure here must not mask the original error that triggered the call.
    {
        printf '%s\n' "=== targetVersion=${targetVersion:-unknown} ==="
        printf '\n'
        printf '%s\n' "=== oc get clusterversion version ==="
        oc get clusterversion version -o wide 2>&1 || true
        printf '\n'
        printf '%s\n' "=== oc describe clusterversion version ==="
        oc describe clusterversion version 2>&1 || true
        printf '\n'
        printf '%s\n' "=== oc get events -A (last 40) ==="
        # tail -40 is informational only; || true covers both transient API errors and
        # the case where the API server is already unreachable mid-upgrade.
        oc get events -A --sort-by='.lastTimestamp' 2>&1 | tail -40 || true
    } > "${artifactFile}"
    : "Wrote upgrade failure diagnostics to ${artifactFile}"
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
# Upgrade hub cluster
#=====================
: "Upgrading hub to version=${targetVersion} channel=${ACM_CLUSTER_UPGRADE_TARGET_CHANNEL}"

if [[ -n "${ACM_CLUSTER_UPGRADE_TARGET_CHANNEL}" ]]; then
    oc patch clusterversion version \
        --type merge \
        -p "$(jq -cn --arg ch "${ACM_CLUSTER_UPGRADE_TARGET_CHANNEL}" '{"spec":{"channel":$ch}}')"
fi

# Patch admin-ack ConfigMap when the Upgradeable condition requires it.
typeset upgradeableMsg='' 
typeset ackKey=''
# || true: a transient API blip here must not abort the step. An empty result
# means no Upgradeable condition is present, so ackKey stays empty and the patch
# is skipped — the subsequent oc adm upgrade will fail loudly if ack is truly required.
upgradeableMsg="$(oc get clusterversion version \
    -o jsonpath='{.status.conditions[?(@.type=="Upgradeable")].message}' || true)"
if [[ -n "${upgradeableMsg}" ]]; then
    # || true: grep exits 1 when no match is found; that is a valid outcome (no ack
    # key embedded in the message), not an error.
    ackKey="$(grep -oE 'ack-[a-zA-Z0-9.-]+' <<< "${upgradeableMsg}" | head -1 || true)"
fi
if [[ -n "${ackKey}" ]]; then
    : "Patching admin-ack '${ackKey}' from Upgradeable condition"
    oc patch configmap admin-acks-upgrades -n openshift-config \
        --type merge \
        -p "$(jq -cn --arg k "${ackKey}" '{data: {($k): "true"}}')" \
        || : "admin-acks-upgrades patch skipped (ConfigMap may not exist on this cluster)"
else
    : "No admin-ack key in Upgradeable condition; skipping patch"
fi

# Strip tag or digest suffix to get bare registry/repo, then re-pin by digest.
typeset repo="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE%:*}"
repo="${repo%@sha256*}"

oc adm upgrade \
    --to-image="${repo}@${digest}" \
    --allow-explicit-upgrade \
    --allow-upgrade-with-warnings \
    --force

#=====================
# Wait for hub cluster upgrade to complete
#=====================
# Two oc wait calls are needed because oc wait supports only one jsonpath condition each.
# The first wait guards against a race: immediately after oc adm upgrade, history[0] still
# reflects the previous upgrade's Completed state. Only once history[0].version matches
# targetVersion is it safe to poll for Completed.
: "Waiting for hub to reach version=${targetVersion} (timeout=${ACM_UPGRADE_TIMEOUT})"

oc wait clusterversion/version \
    --for=jsonpath='{.status.history[0].version}'="${targetVersion}" \
    --timeout="${ACM_UPGRADE_TIMEOUT}" || {
    WriteUpgradeFailureDiagnostics "hub"
    false
}

oc wait clusterversion/version \
    --for=jsonpath='{.status.history[0].state}'="Completed" \
    --timeout="${ACM_UPGRADE_TIMEOUT}" || {
    WriteUpgradeFailureDiagnostics "hub"
    false
}

: "Hub cluster upgraded to ${targetVersion}"
true
