#!/bin/bash
#
# Upgrade ODF on the ACM hub cluster to a new channel after an EUS OCP upgrade.
# Patches the existing odf-operator Subscription channel, waits for OLM to install
# the new CSV (Succeeded), then waits for StorageCluster and NooBaa to return to Ready.
# Intended for EUS scenarios (e.g. stable-4.20 → stable-4.22 post OCP 4.22 upgrade).
# Targets the hub cluster via ${KUBECONFIG}.
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

# Derive ODF major.minor from the channel (e.g. stable-4.22 → 4.22) for the must-gather image tag.
typeset odfVersion="${ODF_UPGRADE_TARGET_CHANNEL#stable-}"

DumpHubOdfUpgradeDiagnostics() {
    typeset artifactDir="${ARTIFACT_DIR}/odf-hub-upgrade"
    mkdir -p "${artifactDir}"
    oc --kubeconfig="${KUBECONFIG}" get storagecluster,cephcluster,noobaa,csv \
        -n "${ODF_INSTALL_NAMESPACE}" -o wide \
        > "${artifactDir}/odf-resources.txt" 2>&1 || true
    oc --kubeconfig="${KUBECONFIG}" get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" -o yaml \
        > "${artifactDir}/subscription.yaml" 2>&1 || true
    oc --kubeconfig="${KUBECONFIG}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" -o yaml \
        > "${artifactDir}/storagecluster.yaml" 2>&1 || true
    oc --kubeconfig="${KUBECONFIG}" describe storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        > "${artifactDir}/storagecluster-describe.txt" 2>&1 || true
    true
}
trap '
    typeset _exitCode=$?
    DumpHubOdfUpgradeDiagnostics
    ((_exitCode)) &&
        oc adm must-gather \
            --image="quay.io/rhceph-dev/ocs-must-gather:latest-${odfVersion}" \
            --dest-dir="${ARTIFACT_DIR}/ocs_must_gather_hub_upgrade" || true
' EXIT

# WaitCsvUpgraded — wait for OLM to install a new CSV after a subscription channel patch.
# Polls subscription.status.installedCSV until it differs from previousCsv, then
# waits for the new CSV to reach Succeeded phase.
# installedCSV uses a poll loop because oc wait --for=jsonpath requires an exact value
# and the new CSV name is unknown until OLM resolves the install plan.
WaitCsvUpgraded() {
    typeset previousCsv="${1:?}"; (($#)) && shift
    typeset newCsvName=''
    (
        SECONDS=0
        while (( SECONDS < odfCsvPollMax )); do
            newCsvName="$(oc --kubeconfig="${KUBECONFIG}" \
                get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
                -n "${ODF_INSTALL_NAMESPACE}" \
                -o jsonpath='{.status.installedCSV}' || true)"
            [[ -n "${newCsvName}" && "${newCsvName}" != "${previousCsv}" ]] && break
            : "Waiting for ODF installedCSV to change from ${previousCsv:-<empty>} (${SECONDS}/${odfCsvPollMax}s)"
            sleep "${odfCsvPollInt}"
        done
        [[ -n "${newCsvName}" && "${newCsvName}" != "${previousCsv}" ]]
        : "ODF CSV advanced to ${newCsvName}; waiting for Succeeded"
        oc --kubeconfig="${KUBECONFIG}" wait "clusterserviceversion/${newCsvName}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            --for=jsonpath='{.status.phase}'=Succeeded \
            --timeout="${odfCsvPollMax}s" 1>/dev/null
        true
    )
    true
}

WaitStorageClusterAndNoobaaReady() {
    : "Waiting for StorageCluster phase=Ready post-upgrade"
    oc --kubeconfig="${KUBECONFIG}" wait \
        "storagecluster/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s" 1>/dev/null
    : "Waiting for NooBaa phase=Ready post-upgrade"
    oc --kubeconfig="${KUBECONFIG}" wait \
        noobaa/noobaa \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s" 1>/dev/null
    true
}

# -- Main -----------------------------------------------------------------------

: "Upgrading ODF hub subscription channel to ${ODF_UPGRADE_TARGET_CHANNEL}"

# Record current installedCSV before patching so WaitCsvUpgraded can detect the change.
typeset previousCsv=""
previousCsv="$(oc --kubeconfig="${KUBECONFIG}" \
    get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
    -n "${ODF_INSTALL_NAMESPACE}" \
    -o jsonpath='{.status.installedCSV}' || true)"
: "Hub ODF current installedCSV: ${previousCsv:-<none>}"

# Patch subscription channel. OLM detects the channel change and auto-creates an
# InstallPlan (installPlanApproval is Automatic from the install step).
oc --kubeconfig="${KUBECONFIG}" patch subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
    -n "${ODF_INSTALL_NAMESPACE}" \
    --type merge \
    -p "$(jq -cn --arg ch "${ODF_UPGRADE_TARGET_CHANNEL}" '{"spec":{"channel":$ch}}')"

WaitCsvUpgraded "${previousCsv}"
WaitStorageClusterAndNoobaaReady

oc --kubeconfig="${KUBECONFIG}" get storagecluster,storageclass \
    -n "${ODF_INSTALL_NAMESPACE}" \
    > "${ARTIFACT_DIR}/odf-hub-upgrade-status.txt"
true
