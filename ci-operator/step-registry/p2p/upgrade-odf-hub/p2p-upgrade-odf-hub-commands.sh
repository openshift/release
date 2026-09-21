#!/bin/bash
#
# Upgrade ODF on the ACM hub cluster through one or more channels after an EUS OCP upgrade.
# Iterates ODF_UPGRADE_CHANNEL_HOPS (comma-separated, e.g. "stable-4.21,stable-4.22"),
# patching the Subscription channel at each hop, waiting for OLM to install the new CSV
# (Succeeded), then waiting for StorageCluster and NooBaa to return to Ready.
# ODF's OLM upgrade graph requires sequential hops — skipping directly from stable-4.20
# to stable-4.22 leaves OLM without an install-plan edge and the CSV never changes.
# Intended for EUS scenarios (e.g. stable-4.20 → stable-4.21 → stable-4.22).
# Targets the hub cluster via ${KUBECONFIG}.
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

# currentChannel is updated before each hop so the EXIT trap can derive the must-gather image tag.
typeset currentChannel=''

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

HubOdfUpgradeCleanup() {
    typeset -i exitCode=$?
    DumpHubOdfUpgradeDiagnostics || true
    if (( exitCode != 0 )); then
        typeset odfVer="${currentChannel#stable-}"
        [[ -n "${odfVer}" ]] && \
            oc adm must-gather \
                --image="quay.io/rhceph-dev/ocs-must-gather:latest-${odfVer}" \
                --dest-dir="${ARTIFACT_DIR}/ocs_must_gather_hub_upgrade" || true
    fi
    exit "${exitCode}"
}
trap HubOdfUpgradeCleanup EXIT

# WaitCsvUpgraded — poll subscription.status.installedCSV until it differs from previousCsv,
# then wait for the new CSV to reach Succeeded phase.
# installedCSV requires a poll loop because oc wait --for=jsonpath requires an exact value
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
        [[ -n "${newCsvName}" && "${newCsvName}" != "${previousCsv}" ]] \
            || { : "ODF installedCSV did not change from ${previousCsv} within ${odfCsvPollMax}s for channel ${currentChannel} — OLM may have no upgrade-graph edge; check catalog source"; false; }
        : "ODF CSV advanced to ${newCsvName} for channel ${currentChannel}; waiting for Succeeded"
        oc --kubeconfig="${KUBECONFIG}" wait "clusterserviceversion/${newCsvName}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            --for=jsonpath='{.status.phase}'=Succeeded \
            --timeout="${odfCsvPollMax}s" 1>/dev/null
        true
    )
}

WaitStorageClusterAndNoobaaReady() {
    : "Waiting for StorageCluster phase=Ready (channel=${currentChannel})"
    oc --kubeconfig="${KUBECONFIG}" wait \
        "storagecluster/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s" 1>/dev/null
    : "Waiting for NooBaa phase=Ready (channel=${currentChannel})"
    oc --kubeconfig="${KUBECONFIG}" wait \
        noobaa/noobaa \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s" 1>/dev/null
    true
}

# -- Main -----------------------------------------------------------------------

[[ -n "${ODF_UPGRADE_CHANNEL_HOPS}" ]] \
    || { : "ODF_UPGRADE_CHANNEL_HOPS is empty — set to comma-separated channel hops e.g. stable-4.21,stable-4.22"; false; }

typeset -a hopChannelsArr=()
IFS=',' read -r -a hopChannelsArr <<< "${ODF_UPGRADE_CHANNEL_HOPS}"
(( ${#hopChannelsArr[@]} >= 1 )) || { : "ODF_UPGRADE_CHANNEL_HOPS parsed to zero entries"; false; }

: "ODF hub channel upgrade via ${#hopChannelsArr[@]} hop(s): ${ODF_UPGRADE_CHANNEL_HOPS}"

typeset previousCsv=''
typeset hopChannel=''

previousCsv="$(oc --kubeconfig="${KUBECONFIG}" \
    get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
    -n "${ODF_INSTALL_NAMESPACE}" \
    -o jsonpath='{.status.installedCSV}' || true)"
: "Hub ODF starting installedCSV: ${previousCsv:-<none>}"

for hopChannel in "${hopChannelsArr[@]}"; do
    hopChannel="${hopChannel//[[:space:]]/}"
    [[ -n "${hopChannel}" ]] || continue
    currentChannel="${hopChannel}"
    : "Hub ODF hop → ${hopChannel} (from installedCSV=${previousCsv:-<none>})"
    oc --kubeconfig="${KUBECONFIG}" patch subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --type merge \
        -p "$(jq -cn --arg ch "${hopChannel}" '{"spec":{"channel":$ch}}')"
    WaitCsvUpgraded "${previousCsv}"
    # Record the new CSV as baseline for the next hop before checking StorageCluster.
    previousCsv="$(oc --kubeconfig="${KUBECONFIG}" \
        get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        -o jsonpath='{.status.installedCSV}' || true)"
    : "Hub ODF hop to ${hopChannel} CSV installed: ${previousCsv}"
    WaitStorageClusterAndNoobaaReady
    oc --kubeconfig="${KUBECONFIG}" get storagecluster,storageclass \
        -n "${ODF_INSTALL_NAMESPACE}" \
        > "${ARTIFACT_DIR}/odf-hub-after-${hopChannel}.txt"
    : "Hub ODF hop to ${hopChannel} complete"
done

true
