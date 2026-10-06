#!/bin/bash
#
# Upgrade ODF on one or more ACM spoke clusters through one or more channels after an EUS
# OCP upgrade. Reads spoke kubeconfigs from SHARED_DIR (same files as
# acm-interop-p2p-cluster-install).
# Iterates ODF_UPGRADE_CHANNEL_HOPS (comma-separated, e.g. "stable-4.21,stable-4.22"),
# patching the Subscription channel at each hop, waiting for OLM to install the new CSV
# (Succeeded), then waiting for StorageCluster operand images to converge (actualImage ==
# desiredImage, version matching the hop) and NooBaa to return to Ready.
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
)" || { printf 'FATAL: failed to fetch EnsureReqs.sh from GitHub\n' >&2; exit 1; }
type -t EnsureReqs 1>/dev/null \
    || { printf 'FATAL: failed to fetch EnsureReqs.sh from GitHub\n' >&2; exit 1; }
EnsureReqs jq

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
    typeset runMustGather="${1:-true}"; (($#)) && shift
    # Strip any channel prefix (stable-/eus-/fast-) so the tag is latest-<major.minor>.
    typeset odfVer="${lastChannel##*-}"
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
    {
        oc --kubeconfig="${kubeconfig}" get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            -o jsonpath='installedCSV={.status.installedCSV} channel={.spec.channel}{"\n"}' || true
        oc --kubeconfig="${kubeconfig}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            -o jsonpath='storageClusterPhase={.status.phase} version={.status.version}{"\n"}' || true
        oc --kubeconfig="${kubeconfig}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            -o jsonpath='cephDesired={.status.images.ceph.desiredImage} cephActual={.status.images.ceph.actualImage}{"\n"}' || true
        oc --kubeconfig="${kubeconfig}" get noobaa/noobaa \
            -n "${ODF_INSTALL_NAMESPACE}" \
            -o jsonpath='noobaaPhase={.status.phase}{"\n"}' || true
    } > "${artifactDir}/odf-upgrade-summary.txt" 2>&1 || true
    if [[ "${runMustGather}" == "true" ]]; then
        oc --kubeconfig="${kubeconfig}" adm must-gather \
            --image="quay.io/rhceph-dev/ocs-must-gather:latest-${odfVer}" \
            --dest-dir="${artifactDir}/ocs_must_gather" || true
    fi
    true
}

# WaitCsvUpgraded — poll subscription.status.installedCSV until it differs from previousCsv,
# then wait for the new CSV to reach Succeeded phase.
# installedCSV requires a poll loop because oc wait --for=jsonpath requires an exact value
# and the new CSV name is unknown until OLM resolves the install plan.
WaitCsvUpgraded() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    # previousCsv may be empty (OLM has not yet reported installedCSV); the arg must still be passed.
    (( $# >= 1 )) || { printf 'FATAL: WaitCsvUpgraded requires previousCsv (may be empty)\n' >&2; return 1; }
    typeset previousCsv="${1}"; shift
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

# StorageClusterHopConverged — 0 when this hop's operands have rolled, not merely Ready.
# A leftover Ready phase from the prior hop can satisfy oc wait immediately after the new
# CSV succeeds; require actualImage==desiredImage and either status.version matching the
# hop or ceph desiredImage changing from the pre-hop snapshot.
# Fields: storageclusters.ocs.openshift.io status.images.{ceph,noobaaCore,noobaaDB}.{desiredImage,actualImage}
# (ocs-operator api/v1 ComponentImageStatus).
StorageClusterHopConverged() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset hopChannel="${1:?}"; (($#)) && shift
    typeset preDesiredCeph="${1-}"
    typeset hopVer="${hopChannel##*-}"
    typeset scJson=''
    scJson="$(oc --kubeconfig="${kubeconfig}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
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
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift
    typeset hopChannel="${1:?}"; (($#)) && shift
    typeset preDesiredCeph="${1-}"
    printf 'INFO: Waiting for StorageCluster hop %s operand completion on %s (images/version, not stale Ready)\n' "${hopChannel}" "${clusterName}" >&2
    (
        SECONDS=0
        while (( SECONDS < odfScPollMax )); do
            if StorageClusterHopConverged "${kubeconfig}" "${hopChannel}" "${preDesiredCeph}"; then
                break
            fi
            : "Waiting for StorageCluster images/version to match hop ${hopChannel} on ${clusterName} (${SECONDS}/${odfScPollMax}s)"
            sleep "${odfCsvPollInt}"
        done
        StorageClusterHopConverged "${kubeconfig}" "${hopChannel}" "${preDesiredCeph}" \
            || { printf 'FATAL: StorageCluster on %s did not complete hop %s within %ss (stale Ready or images not converged)\n' "${clusterName}" "${hopChannel}" "${odfScPollMax}" >&2; false; }
        true
    )
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
    typeset previousCsv='' hopChannel='' preDesiredCeph=''
    typeset -a hopChannelsArr=()
    typeset lastChannel='' lastChannelFile="${resultFile}.channel"
    typeset -i subRc=0
    typeset wasErrexit=false

    # Run the hop loop in a subshell with its own errexit. Do not attach that
    # subshell (or this function) to ||/&& — Bash ignores errexit for every
    # command in those lists, including nested subshells, so a failed patch
    # or wait would still write 0 to resultFile.
    [[ $- == *e* ]] && wasErrexit=true
    set +e
    (
        set -euo pipefail
        shopt -s inherit_errexit
        IFS=',' read -r -a hopChannelsArr <<< "${ODF_UPGRADE_CHANNEL_HOPS}"
        (( ${#hopChannelsArr[@]} >= 1 )) \
            || { printf 'FATAL: ODF_UPGRADE_CHANNEL_HOPS parsed to zero entries for %s\n' "${clusterName}" >&2; false; }
        printf 'INFO: ODF spoke %s channel upgrade via %d hop(s): %s\n' "${clusterName}" "${#hopChannelsArr[@]}" "${ODF_UPGRADE_CHANNEL_HOPS}" >&2

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
            # Snapshot pre-hop desiredImage so a leftover Ready phase cannot complete the wait.
            preDesiredCeph="$(oc --kubeconfig="${kubeconfig}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
                -n "${ODF_INSTALL_NAMESPACE}" \
                -o jsonpath='{.status.images.ceph.desiredImage}' || true)"
            printf 'INFO: Spoke %s ODF hop → %s (from installedCSV=%s preDesiredCeph=%s)\n' "${clusterName}" "${hopChannel}" "${previousCsv:-<none>}" "${preDesiredCeph:-<none>}" >&2
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
            WaitStorageClusterAndNoobaaReady "${kubeconfig}" "${clusterName}" "${hopChannel}" "${preDesiredCeph}"
            oc --kubeconfig="${kubeconfig}" get storagecluster,storageclass \
                -n "${ODF_INSTALL_NAMESPACE}" \
                > "${ARTIFACT_DIR}/odf-spoke-${clusterName}-after-${hopChannel}.txt"
            printf 'INFO: Spoke %s ODF hop to %s complete (installedCSV=%s)\n' "${clusterName}" "${hopChannel}" "${previousCsv:-<none>}" >&2
        done

        # Success-path resource dump (no must-gather) for post-run audit.
        DumpSpokeOdfUpgradeDiagnostics "${clusterName}" "${kubeconfig}" "${lastChannel}" false || true
        printf 'INFO: Spoke %s ODF upgrade complete via %s\n' "${clusterName}" "${ODF_UPGRADE_CHANNEL_HOPS}" >&2
        printf '0' > "${resultFile}"
        true
    )
    subRc=$?
    if (( subRc != 0 )); then
        [[ -f "${lastChannelFile}" ]] && lastChannel="$(<"${lastChannelFile}")"
        DumpSpokeOdfUpgradeDiagnostics "${clusterName}" "${kubeconfig}" "${lastChannel}" || true
        printf '1' > "${resultFile}"
        [[ "${wasErrexit}" == "true" ]] && set -e
        return 1
    fi
    [[ "${wasErrexit}" == "true" ]] && set -e
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

typeset -a clusterNamesArr=()
mapfile -t clusterNamesArr < <(LoadSpokeClusterNames)

typeset -a spokeKubeconfigsArr=()
mapfile -t spokeKubeconfigsArr < <(LoadSpokeKubeconfigs "${clusterNamesArr[@]}")

resultsDir="$(mktemp -d "${ARTIFACT_DIR}/odf-spoke-upgrade.XXXXXX")"

typeset -i failedCount=0 idx=0 waitRc=0
typeset resultFile='' storedRc=''

if (( ${#clusterNamesArr[@]} == 1 )); then
    # Single spoke: call directly to avoid background subprocess overhead.
    # Do not use || true here — that disables errexit inside UpgradeOdfOnSpoke
    # (including its hop-loop subshell) so a failed patch/wait can write 0.
    resultFile="${resultsDir}/cluster-1.result"
    set +e
    UpgradeOdfOnSpoke "${clusterNamesArr[0]}" "${spokeKubeconfigsArr[0]}" "${resultFile}"
    waitRc=$?
    set -e
    if [[ -f "${resultFile}" ]]; then
        storedRc="$(<"${resultFile}")"
        [[ "${storedRc}" == '0' ]] || failedCount=1
    elif (( waitRc != 0 )); then
        failedCount=1
    fi
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

if (( failedCount != 0 )); then
    printf 'FATAL: %d spoke ODF upgrade(s) failed\n' "${failedCount}" >&2
    false
fi
printf 'INFO: All spoke ODF upgrades succeeded\n' >&2
true
