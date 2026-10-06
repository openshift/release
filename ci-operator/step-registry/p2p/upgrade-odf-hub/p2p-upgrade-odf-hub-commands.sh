#!/bin/bash
#
# Upgrade ODF on the ACM hub cluster through one or more channels after an EUS OCP upgrade.
# Iterates ODF_UPGRADE_CHANNEL_HOPS (comma-separated, e.g. "stable-4.21,stable-4.22"),
# patching the Subscription channel at each hop, waiting for OLM to install the new CSV
# (Succeeded), then waiting for StorageCluster operand images to converge (actualImage ==
# desiredImage, version matching the hop) and NooBaa to return to Ready.
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
)" || { printf 'FATAL: failed to fetch EnsureReqs.sh from GitHub\n' >&2; exit 1; }
type -t EnsureReqs 1>/dev/null \
    || { printf 'FATAL: failed to fetch EnsureReqs.sh from GitHub\n' >&2; exit 1; }
EnsureReqs jq

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
    {
        oc --kubeconfig="${KUBECONFIG}" get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            -o jsonpath='installedCSV={.status.installedCSV} channel={.spec.channel}{"\n"}' || true
        oc --kubeconfig="${KUBECONFIG}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            -o jsonpath='storageClusterPhase={.status.phase} version={.status.version}{"\n"}' || true
        oc --kubeconfig="${KUBECONFIG}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            -o jsonpath='cephDesired={.status.images.ceph.desiredImage} cephActual={.status.images.ceph.actualImage}{"\n"}' || true
        oc --kubeconfig="${KUBECONFIG}" get noobaa/noobaa \
            -n "${ODF_INSTALL_NAMESPACE}" \
            -o jsonpath='noobaaPhase={.status.phase}{"\n"}' || true
    } > "${artifactDir}/odf-upgrade-summary.txt" 2>&1 || true
    true
}

HubOdfUpgradeCleanup() {
    typeset -i exitCode=$?
    DumpHubOdfUpgradeDiagnostics || true
    if (( exitCode != 0 )); then
        # Strip any channel prefix (stable-/eus-/fast-) so the tag is latest-<major.minor>.
        typeset odfVer="${currentChannel##*-}"
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
    # previousCsv may be empty (OLM has not yet reported installedCSV); the arg must still be passed.
    (( $# >= 1 )) || { printf 'FATAL: WaitCsvUpgraded requires previousCsv (may be empty)\n' >&2; return 1; }
    typeset previousCsv="${1}"; shift
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

# StorageClusterHopConverged — 0 when this hop's operands have rolled, not merely Ready.
# A leftover Ready phase from the prior hop can satisfy oc wait immediately after the new
# CSV succeeds; require actualImage==desiredImage and either status.version matching the
# hop or ceph desiredImage changing from the pre-hop snapshot.
# Fields: storageclusters.ocs.openshift.io status.images.{ceph,noobaaCore,noobaaDB}.{desiredImage,actualImage}
# (ocs-operator api/v1 ComponentImageStatus).
StorageClusterHopConverged() {
    typeset hopChannel="${1:?}"; (($#)) && shift
    typeset preDesiredCeph="${1-}"
    typeset hopVer="${hopChannel##*-}"
    typeset scJson=''
    scJson="$(oc --kubeconfig="${KUBECONFIG}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" -o json || true)"
    [[ -n "${scJson}" ]] || return 1
    jq -e --arg hopVer "${hopVer}" --arg preDesiredCeph "${preDesiredCeph}" '
        (.status.phase == "Ready")
        and (.status.images.ceph.desiredImage | type == "string" and length > 0)
        and (.status.images.ceph.actualImage == .status.images.ceph.desiredImage)
        and (
            (.status.images.noobaaCore.desiredImage | type != "string")
            or (.status.images.noobaaCore.desiredImage | length == 0)
            or (.status.images.noobaaCore.actualImage == .status.images.noobaaCore.desiredImage)
        )
        and (
            (.status.images.noobaaDB.desiredImage | type != "string")
            or (.status.images.noobaaDB.desiredImage | length == 0)
            or (.status.images.noobaaDB.actualImage == .status.images.noobaaDB.desiredImage)
        )
        and (
            (
                (.status.version | type == "string")
                and (
                    (.status.version == $hopVer)
                    or (.status.version | startswith($hopVer + "."))
                    or (.status.version | startswith($hopVer + "-"))
                )
            )
            or (
                ($preDesiredCeph | length > 0)
                and (.status.images.ceph.desiredImage != $preDesiredCeph)
            )
        )
    ' <<<"${scJson}" 1>/dev/null
}

WaitStorageClusterAndNoobaaReady() {
    typeset preDesiredCeph="${1-}"
    printf 'INFO: Waiting for StorageCluster hop %s operand completion (images/version, not stale Ready)\n' "${currentChannel}" >&2
    (
        SECONDS=0
        while (( SECONDS < odfScPollMax )); do
            if StorageClusterHopConverged "${currentChannel}" "${preDesiredCeph}"; then
                break
            fi
            : "Waiting for StorageCluster images/version to match hop ${currentChannel} (${SECONDS}/${odfScPollMax}s)"
            sleep "${odfCsvPollInt}"
        done
        StorageClusterHopConverged "${currentChannel}" "${preDesiredCeph}" \
            || { printf 'FATAL: StorageCluster did not complete hop %s within %ss (stale Ready or images not converged)\n' "${currentChannel}" "${odfScPollMax}" >&2; false; }
        true
    )
    : "Waiting for NooBaa phase=Ready (channel=${currentChannel})"
    oc --kubeconfig="${KUBECONFIG}" wait \
        noobaa/noobaa \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s" 1>/dev/null
    true
}

# ValidateUpgradeChannelHops — require a non-empty, comma-separated list of
# <prefix>-<major>.<minor> channels in strictly ascending version order.
ValidateUpgradeChannelHops() {
    typeset hops="${ODF_UPGRADE_CHANNEL_HOPS}"
    typeset -a hopsArr=()
    typeset hop='' prevVer='' curVer=''
    typeset -i prevMajor=0 prevMinor=0 curMajor=0 curMinor=0
    [[ -n "${hops}" ]] \
        || { printf 'FATAL: ODF_UPGRADE_CHANNEL_HOPS is empty — set to comma-separated hops e.g. stable-4.21,stable-4.22\n' >&2; return 1; }
    IFS=',' read -r -a hopsArr <<< "${hops}"
    (( ${#hopsArr[@]} >= 1 )) \
        || { printf 'FATAL: ODF_UPGRADE_CHANNEL_HOPS parsed to zero entries\n' >&2; return 1; }
    for hop in "${hopsArr[@]}"; do
        hop="${hop//[[:space:]]/}"
        [[ -n "${hop}" ]] || continue
        [[ "${hop}" =~ ^[A-Za-z0-9._-]+-[0-9]+\.[0-9]+$ ]] \
            || { printf 'FATAL: invalid ODF channel hop %s (expected <prefix>-<major>.<minor> e.g. stable-4.21)\n' "${hop}" >&2; return 1; }
        curVer="${hop##*-}"
        IFS='.' read -r curMajor curMinor <<< "${curVer}"
        if [[ -n "${prevVer}" ]]; then
            (( curMajor > prevMajor || (curMajor == prevMajor && curMinor > prevMinor) )) \
                || { printf 'FATAL: ODF_UPGRADE_CHANNEL_HOPS not in ascending order (%s then %s)\n' "${prevVer}" "${curVer}" >&2; return 1; }
        fi
        prevVer="${curVer}"
        prevMajor="${curMajor}"
        prevMinor="${curMinor}"
    done
    [[ -n "${prevVer}" ]] \
        || { printf 'FATAL: ODF_UPGRADE_CHANNEL_HOPS parsed to zero entries\n' >&2; return 1; }
    true
}

# -- Main -----------------------------------------------------------------------

ValidateUpgradeChannelHops

typeset -a hopChannelsArr=()
IFS=',' read -r -a hopChannelsArr <<< "${ODF_UPGRADE_CHANNEL_HOPS}"
(( ${#hopChannelsArr[@]} >= 1 )) || { printf 'FATAL: ODF_UPGRADE_CHANNEL_HOPS parsed to zero entries\n' >&2; false; }

printf 'INFO: ODF hub channel upgrade via %d hop(s): %s\n' "${#hopChannelsArr[@]}" "${ODF_UPGRADE_CHANNEL_HOPS}" >&2

typeset previousCsv=''
typeset hopChannel=''
typeset preDesiredCeph=''

previousCsv="$(oc --kubeconfig="${KUBECONFIG}" \
    get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
    -n "${ODF_INSTALL_NAMESPACE}" \
    -o jsonpath='{.status.installedCSV}' || true)"
: "Hub ODF starting installedCSV: ${previousCsv:-<none>}"

for hopChannel in "${hopChannelsArr[@]}"; do
    hopChannel="${hopChannel//[[:space:]]/}"
    [[ -n "${hopChannel}" ]] || continue
    currentChannel="${hopChannel}"
    # Snapshot pre-hop desiredImage so a leftover Ready phase cannot complete the wait.
    preDesiredCeph="$(oc --kubeconfig="${KUBECONFIG}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        -o jsonpath='{.status.images.ceph.desiredImage}' || true)"
    printf 'INFO: Hub ODF hop → %s (from installedCSV=%s preDesiredCeph=%s)\n' "${hopChannel}" "${previousCsv:-<none>}" "${preDesiredCeph:-<none>}" >&2
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
    WaitStorageClusterAndNoobaaReady "${preDesiredCeph}"
    oc --kubeconfig="${KUBECONFIG}" get storagecluster,storageclass \
        -n "${ODF_INSTALL_NAMESPACE}" \
        > "${ARTIFACT_DIR}/odf-hub-after-${hopChannel}.txt"
    printf 'INFO: Hub ODF hop to %s complete (installedCSV=%s)\n' "${hopChannel}" "${previousCsv:-<none>}" >&2
done

printf 'INFO: Hub ODF upgrade complete via %s\n' "${ODF_UPGRADE_CHANNEL_HOPS}" >&2
true
