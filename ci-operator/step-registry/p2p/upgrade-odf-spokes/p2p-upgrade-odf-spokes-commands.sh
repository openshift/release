#!/bin/bash
#
# Upgrade ODF on one or more ACM spoke clusters to a new channel after an EUS OCP upgrade.
# Reads spoke kubeconfigs from SHARED_DIR (same files as acm-interop-p2p-cluster-install).
# Patches the existing odf-operator Subscription channel, waits for OLM to install the new
# CSV (Succeeded), then waits for StorageCluster and NooBaa to return to Ready.
# Intended for EUS scenarios (e.g. stable-4.20 → stable-4.22 post OCP 4.22 upgrade).
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/f63f1f606b1d76f6ef2a3e78b4ec1ad7362d4fac/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset -i odfCsvPollInt="${ODF_CSV_POLL_INTERVAL_SECONDS}"
typeset -i odfCsvPollMax="${ODF_CSV_POLL_TIMEOUT_SECONDS}"
typeset -i odfScPollMax="${ODF_STORAGECLUSTER_POLL_TIMEOUT_SECONDS}"

typeset resultsDir=""

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
    typeset odfVersion="${ODF_UPGRADE_TARGET_CHANNEL#stable-}"
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
        --image="quay.io/rhceph-dev/ocs-must-gather:latest-${odfVersion}" \
        --dest-dir="${artifactDir}/ocs_must_gather" || true
    true
}

# WaitCsvUpgraded — wait for OLM to install a new CSV after a subscription channel patch.
# Polls subscription.status.installedCSV until it differs from previousCsv, then
# waits for the new CSV to reach Succeeded phase.
WaitCsvUpgraded() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset previousCsv="${1:?}"; (($#)) && shift
    typeset newCsvName=''
    (
        SECONDS=0
        while (( SECONDS < odfCsvPollMax )); do
            newCsvName="$(oc --kubeconfig="${kubeconfig}" \
                get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
                -n "${ODF_INSTALL_NAMESPACE}" \
                -o jsonpath='{.status.installedCSV}' || true)"
            [[ -n "${newCsvName}" && "${newCsvName}" != "${previousCsv}" ]] && break
            : "Waiting for ODF installedCSV to change from ${previousCsv:-<empty>} (${SECONDS}/${odfCsvPollMax}s)"
            sleep "${odfCsvPollInt}"
        done
        [[ -n "${newCsvName}" && "${newCsvName}" != "${previousCsv}" ]]
        : "ODF CSV advanced to ${newCsvName}; waiting for Succeeded"
        oc --kubeconfig="${kubeconfig}" wait "clusterserviceversion/${newCsvName}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            --for=jsonpath='{.status.phase}'=Succeeded \
            --timeout="${odfCsvPollMax}s" 1>/dev/null
        true
    )
    true
}

WaitStorageClusterAndNoobaaReady() {
    typeset kubeconfig="${1:?}"
    : "Waiting for StorageCluster phase=Ready post-upgrade"
    oc --kubeconfig="${kubeconfig}" wait \
        "storagecluster/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s" 1>/dev/null
    : "Waiting for NooBaa phase=Ready post-upgrade"
    oc --kubeconfig="${kubeconfig}" wait \
        noobaa/noobaa \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s" 1>/dev/null
    true
}

# UpgradeOdfOnSpoke — upgrade ODF on one spoke; writes 0/1 to resultFile.
UpgradeOdfOnSpoke() {
    typeset clusterName="${1:?}"
    typeset kubeconfig="${2:?}"
    typeset resultFile="${3:?}"
    typeset previousCsv=""

    (
        : "Upgrading ODF on spoke ${clusterName} to channel ${ODF_UPGRADE_TARGET_CHANNEL}"

        # Record current installedCSV before patching so WaitCsvUpgraded can detect change.
        previousCsv="$(oc --kubeconfig="${kubeconfig}" \
            get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            -o jsonpath='{.status.installedCSV}' || true)"
        : "Spoke ${clusterName} ODF current installedCSV: ${previousCsv:-<none>}"

        # Patch subscription channel. OLM auto-creates an InstallPlan (Automatic approval).
        oc --kubeconfig="${kubeconfig}" patch subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            --type merge \
            -p "$(jq -cn --arg ch "${ODF_UPGRADE_TARGET_CHANNEL}" '{"spec":{"channel":$ch}}')"

        WaitCsvUpgraded "${kubeconfig}" "${previousCsv}"
        WaitStorageClusterAndNoobaaReady "${kubeconfig}"

        oc --kubeconfig="${kubeconfig}" get storagecluster,storageclass \
            -n "${ODF_INSTALL_NAMESPACE}" \
            > "${ARTIFACT_DIR}/odf-spoke-upgrade-${clusterName}-status.txt"

        printf '0' > "${resultFile}"
        true
    ) || {
        DumpSpokeOdfUpgradeDiagnostics "${clusterName}" "${kubeconfig}" || true
        printf '1' > "${resultFile}"
        false
    }
}

# -- Main -----------------------------------------------------------------------

typeset -a clusterNamesArr=()
mapfile -t clusterNamesArr < <(LoadSpokeClusterNames)

typeset -a spokeKubeconfigsArr=()
mapfile -t spokeKubeconfigsArr < <(LoadSpokeKubeconfigs "${clusterNamesArr[@]}")

resultsDir="$(mktemp -d "${ARTIFACT_DIR}/odf-spoke-upgrade.XXXXXX")"

typeset -i failedCount=0 idx waitRc=0
typeset resultFile="" storedRc=""

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
            [[ "${storedRc}" == '0' ]] || (( ++failedCount ))
        elif (( waitRc != 0 )); then
            (( ++failedCount ))
        fi
    done
fi

(( failedCount == 0 ))
true
