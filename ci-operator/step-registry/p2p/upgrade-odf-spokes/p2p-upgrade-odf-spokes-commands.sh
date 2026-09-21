#!/bin/bash
#
# Upgrade ODF on one or more ACM spoke clusters through one or more channels after an EUS
# OCP upgrade. Reads spoke kubeconfigs from SHARED_DIR (same files as
# acm-interop-p2p-cluster-install).
# Iterates ODF_UPGRADE_CHANNEL_HOPS (comma-separated, e.g. "stable-4.21,stable-4.22"),
# patching the Subscription channel at each hop, waiting for OLM to install the new CSV
# (Succeeded), then waiting for StorageCluster and NooBaa to return to Ready.
# ODF's OLM upgrade graph requires sequential hops — skipping directly from stable-4.20
# to stable-4.22 leaves OLM without an install-plan edge and the CSV never changes.
# Multiple spokes are upgraded in parallel.
# Intended for EUS scenarios (e.g. stable-4.20 → stable-4.21 → stable-4.22).
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a fURLArr=()
    type -t wget 1>/dev/null && fURLArr=(wget -nv -O-) || fURLArr=(curl -fsSL)
    "${fURLArr[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/f63f1f606b1d76f6ef2a3e78b4ec1ad7362d4fac/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset -i odfCsvPollInt="${ODF_CSV_POLL_INTERVAL_SECONDS}"
typeset -i odfCsvPollMax="${ODF_CSV_POLL_TIMEOUT_SECONDS}"
typeset -i odfScPollMax="${ODF_STORAGECLUSTER_POLL_TIMEOUT_SECONDS}"

typeset resultsDir=''

Cleanup() {
    [[ -n "${resultsDir}" && -d "${resultsDir}" ]] && rm -rf "${resultsDir}"
    true
}
trap Cleanup EXIT

# LoadSpokeClusterNames — read cluster names from SHARED_DIR multi- or single-spoke files.
LoadSpokeClusterNames() {
    typeset -a clusterNamesArr=()
    if [[ -f "${SHARED_DIR}/managed-cluster-names" ]]; then
        mapfile -t clusterNamesArr < "${SHARED_DIR}/managed-cluster-names"
    elif [[ -f "${SHARED_DIR}/managed-cluster-name" ]]; then
        clusterNamesArr+=("$(<"${SHARED_DIR}/managed-cluster-name")")
    else
        : 'No spoke cluster name files in SHARED_DIR'
        false
    fi
    (( ${#clusterNamesArr[@]} >= 1 ))
    printf '%s\n' "${clusterNamesArr[@]}"
    true
}

# LoadSpokeKubeconfigs — resolve per-spoke kubeconfig paths aligned with clusterNamesArr.
LoadSpokeKubeconfigs() {
    typeset -a clusterNamesArr=("${@}")
    typeset -a spokeKubeconfigsArr=()
    typeset -i kcIdx=0 idx=0
    typeset kcFile=''
    for (( kcIdx = 0; kcIdx < ${#clusterNamesArr[@]}; kcIdx++ )); do
        idx=$(( kcIdx + 1 ))
        kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${idx}"
        if [[ ! -f "${kcFile}" && ${#clusterNamesArr[@]} -eq 1 ]]; then
            kcFile="${SHARED_DIR}/managed-cluster-kubeconfig"
        fi
        [[ -f "${kcFile}" ]]
        spokeKubeconfigsArr+=("${kcFile}")
    done
    printf '%s\n' "${spokeKubeconfigsArr[@]}"
    true
}

DumpSpokeOdfUpgradeDiagnostics() {
    typeset clusterName="${1:?}"; (($#)) && shift
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset lastChannel="${1:-unknown}"; (($#)) && shift
    typeset odfVer="${lastChannel#stable-}"
    typeset artifactDir="${ARTIFACT_DIR}/odf-spoke-upgrade-${clusterName}"
    mkdir -p "${artifactDir}"
    oc --kubeconfig="${kubeconfig}" get storagecluster,cephcluster,noobaa,csv,subscription \
        -n "${ODF_INSTALL_NAMESPACE}" -o wide \
        > "${artifactDir}/odf-resources.txt" 2>&1 || true
    oc --kubeconfig="${kubeconfig}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" -o yaml \
        > "${artifactDir}/storagecluster.yaml" 2>&1 || true
    oc --kubeconfig="${kubeconfig}" describe storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        > "${artifactDir}/storagecluster-describe.txt" 2>&1 || true
    oc --kubeconfig="${kubeconfig}" adm must-gather \
        --image="quay.io/rhceph-dev/ocs-must-gather:latest-${odfVer}" \
        --dest-dir="${artifactDir}/ocs_must_gather" || true
    true
}

# WaitCsvUpgraded — poll subscription.status.installedCSV until it differs from previousCsv,
# then wait for the new CSV to reach Succeeded phase.
# installedCSV requires a poll loop because oc wait --for=jsonpath requires an exact value
# and the new CSV name is unknown until OLM resolves the install plan.
WaitCsvUpgraded() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset previousCsv="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift
    typeset hopChannel="${1:?}"; (($#)) && shift
    typeset newCsvName=''
    (
        SECONDS=0
        while (( SECONDS < odfCsvPollMax )); do
            newCsvName="$(oc --kubeconfig="${kubeconfig}" \
                get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
                -n "${ODF_INSTALL_NAMESPACE}" \
                -o jsonpath='{.status.installedCSV}' || true)"
            [[ -n "${newCsvName}" && "${newCsvName}" != "${previousCsv}" ]] && break
            : "Waiting for ODF installedCSV to change from ${previousCsv:-<empty>} on ${clusterName} (${SECONDS}/${odfCsvPollMax}s)"
            sleep "${odfCsvPollInt}"
        done
        [[ -n "${newCsvName}" && "${newCsvName}" != "${previousCsv}" ]] \
            || { : "ODF installedCSV did not change from ${previousCsv} within ${odfCsvPollMax}s on ${clusterName} for channel ${hopChannel} — OLM may have no upgrade-graph edge; check catalog source"; false; }
        : "ODF CSV advanced to ${newCsvName} on ${clusterName} for channel ${hopChannel}; waiting for Succeeded"
        oc --kubeconfig="${kubeconfig}" wait "clusterserviceversion/${newCsvName}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            --for=jsonpath='{.status.phase}'=Succeeded \
            --timeout="${odfCsvPollMax}s" 1>/dev/null
        true
    )
}

WaitStorageClusterAndNoobaaReady() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift
    typeset hopChannel="${1:?}"; (($#)) && shift
    : "Waiting for StorageCluster phase=Ready on ${clusterName} (channel=${hopChannel})"
    oc --kubeconfig="${kubeconfig}" wait \
        "storagecluster/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s" 1>/dev/null
    : "Waiting for NooBaa phase=Ready on ${clusterName} (channel=${hopChannel})"
    oc --kubeconfig="${kubeconfig}" wait \
        noobaa/noobaa \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s" 1>/dev/null
    true
}

# UpgradeOdfOnSpoke — upgrade ODF on one spoke through all channel hops; writes 0/1 to resultFile.
UpgradeOdfOnSpoke() {
    typeset clusterName="${1:?}"; (($#)) && shift
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset resultFile="${1:?}"; (($#)) && shift
    typeset previousCsv='' hopChannel=''
    typeset -a hopChannelsArr=()
    typeset lastChannel='' lastChannelFile="${resultFile}.channel"

    (
        IFS=',' read -r -a hopChannelsArr <<< "${ODF_UPGRADE_CHANNEL_HOPS}"
        (( ${#hopChannelsArr[@]} >= 1 )) \
            || { : "ODF_UPGRADE_CHANNEL_HOPS parsed to zero entries for ${clusterName}"; false; }
        : "ODF spoke ${clusterName} channel upgrade via ${#hopChannelsArr[@]} hop(s): ${ODF_UPGRADE_CHANNEL_HOPS}"

        previousCsv="$(oc --kubeconfig="${kubeconfig}" \
            get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            -o jsonpath='{.status.installedCSV}' || true)"
        : "Spoke ${clusterName} ODF starting installedCSV: ${previousCsv:-<none>}"

        for hopChannel in "${hopChannelsArr[@]}"; do
            hopChannel="${hopChannel//[[:space:]]/}"
            [[ -n "${hopChannel}" ]] || continue
            lastChannel="${hopChannel}"
            # Persist hop channel outside the subshell so failure diagnostics can
            # derive the ocs-must-gather image tag (subshell assignments do not propagate).
            printf '%s' "${lastChannel}" > "${lastChannelFile}"
            : "Spoke ${clusterName} ODF hop → ${hopChannel} (from installedCSV=${previousCsv:-<none>})"
            oc --kubeconfig="${kubeconfig}" patch subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
                -n "${ODF_INSTALL_NAMESPACE}" \
                --type merge \
                -p "$(jq -cn --arg ch "${hopChannel}" '{"spec":{"channel":$ch}}')"
            WaitCsvUpgraded "${kubeconfig}" "${previousCsv}" "${clusterName}" "${hopChannel}"
            # Record new CSV as baseline for the next hop before checking StorageCluster.
            previousCsv="$(oc --kubeconfig="${kubeconfig}" \
                get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
                -n "${ODF_INSTALL_NAMESPACE}" \
                -o jsonpath='{.status.installedCSV}' || true)"
            : "Spoke ${clusterName} ODF hop to ${hopChannel} CSV installed: ${previousCsv}"
            WaitStorageClusterAndNoobaaReady "${kubeconfig}" "${clusterName}" "${hopChannel}"
            oc --kubeconfig="${kubeconfig}" get storagecluster,storageclass \
                -n "${ODF_INSTALL_NAMESPACE}" \
                > "${ARTIFACT_DIR}/odf-spoke-${clusterName}-after-${hopChannel}.txt"
            : "Spoke ${clusterName} ODF hop to ${hopChannel} complete"
        done

        printf '0' > "${resultFile}"
        true
    ) || {
        [[ -f "${lastChannelFile}" ]] && lastChannel="$(<"${lastChannelFile}")"
        DumpSpokeOdfUpgradeDiagnostics "${clusterName}" "${kubeconfig}" "${lastChannel}" || true
        printf '1' > "${resultFile}"
        false
    }
    true
}

# -- Main -----------------------------------------------------------------------

[[ -n "${ODF_UPGRADE_CHANNEL_HOPS}" ]] \
    || { : "ODF_UPGRADE_CHANNEL_HOPS is empty — set to comma-separated channel hops e.g. stable-4.21,stable-4.22"; false; }

typeset -a clusterNamesArr=()
mapfile -t clusterNamesArr < <(LoadSpokeClusterNames)

typeset -a spokeKubeconfigsArr=()
mapfile -t spokeKubeconfigsArr < <(LoadSpokeKubeconfigs "${clusterNamesArr[@]}")

resultsDir="$(mktemp -d "${ARTIFACT_DIR}/odf-spoke-upgrade.XXXXXX")"

typeset -i failedCount=0 idx=0 waitRc=0
typeset resultFile='' storedRc=''

if (( ${#clusterNamesArr[@]} == 1 )); then
    # Single spoke: call directly to avoid background subprocess overhead.
    resultFile="${resultsDir}/cluster-1.result"
    UpgradeOdfOnSpoke "${clusterNamesArr[0]}" "${spokeKubeconfigsArr[0]}" "${resultFile}" || true
    storedRc="$(<"${resultFile}")"
    [[ "${storedRc}" == '0' ]] || failedCount=1
else
    # Multiple spokes: upgrade in parallel so total wall-clock time is ~1x per-spoke.
    typeset -a pidsArr=()
    for (( idx = 0; idx < ${#clusterNamesArr[@]}; idx++ )); do
        resultFile="${resultsDir}/cluster-$(( idx + 1 )).result"
        UpgradeOdfOnSpoke "${clusterNamesArr[idx]}" "${spokeKubeconfigsArr[idx]}" "${resultFile}" &
        pidsArr+=($!)
    done
    for (( idx = 0; idx < ${#pidsArr[@]}; idx++ )); do
        resultFile="${resultsDir}/cluster-$(( idx + 1 )).result"
        waitRc=0
        wait "${pidsArr[idx]}" || waitRc=$?
        if [[ -f "${resultFile}" ]]; then
            storedRc="$(<"${resultFile}")"
            [[ "${storedRc}" == '0' ]] || (( ++failedCount )) || true
        elif (( waitRc != 0 )); then
            (( ++failedCount )) || true
        fi
    done
fi

(( failedCount == 0 ))
true
