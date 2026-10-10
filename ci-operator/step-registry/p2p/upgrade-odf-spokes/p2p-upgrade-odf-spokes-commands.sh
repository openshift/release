#!/bin/bash
#
# Upgrade ODF on one or more ACM spoke clusters through one or more channels after an EUS
# OCP upgrade. Reads spoke kubeconfigs from SHARED_DIR (same files as
# acm-interop-p2p-cluster-install).
# Iterates ODF_UPGRADE_CHANNEL_HOPS (comma-separated, e.g. "stable-4.21,stable-4.22").
# Each hop retargets the odf-operator pkgs ConfigMap (PKGS_CONFIG_MAP_NAME) from the
# pre-hop channel to the hop channel, then patches Subscriptions still on that pre-hop
# channel (odf-operator and dependencies such as odf-csi-addons-operator). The running
# ODF operator copies ConfigMap channels back onto dependency Subscriptions, so the
# ConfigMap has to move first or it writes the old channel back. ocs-client-operator is
# skipped until StorageCluster hop completion: webhook subscription.ocs.openshift.io
# denies a client channel that does not match StorageClient desired-subscription-channel.
# Then waits for OLM to install the new CSV (Succeeded) and for StorageCluster operand
# images to converge (actualImage == desiredImage, version matching the hop) and NooBaa
# to return to Ready, then aligns ocs-client-operator.
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
    oc --kubeconfig="${kubeconfig}" get storagecluster,cephcluster,noobaa,csv,subscription,storageclient \
        -n "${ODF_INSTALL_NAMESPACE}" -o wide \
        > "${artifactDir}/odf-resources.txt" 2>&1 || true
    oc --kubeconfig="${kubeconfig}" get storageclient -A -o yaml \
        > "${artifactDir}/storageclient.yaml" 2>&1 || true
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
        oc --kubeconfig="${kubeconfig}" get subscription.operators.coreos.com \
            -n "${ODF_INSTALL_NAMESPACE}" \
            -o jsonpath='{range .items[*]}subscription={.metadata.name} channel={.spec.channel}{"\n"}{end}' || true
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
    (( $# >= 2 )) || { printf 'FATAL: WaitCsvUpgraded requires previousCsv and fromChannel\n' >&2; return 1; }
    typeset previousCsv="${1}"; shift
    typeset clusterName="${1:?}"; (($#)) && shift
    typeset hopChannel="${1:?}"; (($#)) && shift
    typeset fromChannel="${1:?}"; (($#)) && shift
    typeset newCsvName=''
    (
        SECONDS=0
        while (( SECONDS < odfCsvPollMax )); do
            # Re-apply while polling. The 4.20 operator reconciles Subscription generation
            # changes from its pkgs ConfigMap and can write the pre-hop channel back.
            AlignOdfChannelsForHop "${kubeconfig}" "${fromChannel}" "${hopChannel}"
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

# OdfPkgsConfigMapName — name of the ConfigMap the running odf-operator reconciles
# Subscription channels from (deployment env PKGS_CONFIG_MAP_NAME).
OdfPkgsConfigMapName() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset cmName=''
    cmName="$(oc --kubeconfig="${kubeconfig}" get deployment \
        -n "${ODF_INSTALL_NAMESPACE}" -o json \
        | jq -r '[.items[]?.spec.template.spec.containers[]?.env[]?
            | select(.name=="PKGS_CONFIG_MAP_NAME") | .value]
            | map(select(length > 0)) | unique | .[0] // empty')"
    [[ -n "${cmName}" ]] \
        || { printf 'FATAL: PKGS_CONFIG_MAP_NAME is not set on any deployment in %s\n' "${ODF_INSTALL_NAMESPACE}" >&2; return 1; }
    printf '%s' "${cmName}"
}

# RetargetOdfPkgsConfigMap — rewrite pkgs ConfigMap records whose channel line is
# exactly "channel: <fromChannel>" to the hop channel. Other channels (alpha, IBM
# stable-1.x, and so on) stay as they are. The odf-operator SubscriptionReconciler
# copies these records onto dependency Subscriptions.
RetargetOdfPkgsConfigMap() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset fromChannel="${1:?}"; (($#)) && shift
    typeset hopChannel="${1:?}"; (($#)) && shift
    typeset cmName='' cmJson='' patchJson=''
    [[ "${fromChannel}" == "${hopChannel}" ]] && return 0
    cmName="$(OdfPkgsConfigMapName "${kubeconfig}")"
    cmJson="$(oc --kubeconfig="${kubeconfig}" get configmap "${cmName}" \
        -n "${ODF_INSTALL_NAMESPACE}" -o json)"
    patchJson="$(jq -c --arg from "${fromChannel}" --arg to "${hopChannel}" '
        def retarget:
            split("\n")
            | map(if . == ("channel: " + $from) then "channel: " + $to else . end)
            | join("\n");
        (.data // {})
        | with_entries(select(.value | split("\n") | index("channel: " + $from)))
        | with_entries(select(
            (.key != "OCS_CLIENT")
            and ((.value | split("\n") | index("pkg: ocs-client-operator")) | not)
          ))
        | with_entries(.value |= retarget)
        | if . == {} then empty else {data: .} end
    ' <<<"${cmJson}")"
    if [[ -z "${patchJson}" ]]; then
        printf 'INFO: ConfigMap %s has no channel %s records\n' "${cmName}" "${fromChannel}" >&2
        return 0
    fi
    printf 'INFO: Retargeting ConfigMap %s channel %s → %s\n' "${cmName}" "${fromChannel}" "${hopChannel}" >&2
    oc --kubeconfig="${kubeconfig}" patch configmap "${cmName}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --type merge \
        -p "${patchJson}"
    true
}

# PatchOdfNamespaceChannels — move Subscriptions still on fromChannel to hopChannel.
# Only the pre-hop channel is changed, so unrelated Subscriptions in the namespace stay put.
PatchOdfNamespaceChannels() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset fromChannel="${1:?}"; (($#)) && shift
    typeset hopChannel="${1:?}"; (($#)) && shift
    typeset subsJson='' subName='' subChannel=''
    [[ "${fromChannel}" == "${hopChannel}" ]] && return 0
    subsJson="$(oc --kubeconfig="${kubeconfig}" get subscription.operators.coreos.com \
        -n "${ODF_INSTALL_NAMESPACE}" -o json)"
    while IFS=$'\t' read -r subName subChannel; do
        [[ -n "${subName}" ]] || continue
        [[ "${subChannel}" == "${fromChannel}" ]] || continue
        # ocs-client-operator is gated by webhook subscription.ocs.openshift.io.
        # It rejects a channel that does not match StorageClient
        # desired-subscription-channel until the StorageCluster hop finishes.
        if [[ "${subName}" == *ocs-client-operator* ]]; then
            printf 'INFO: Skipping %s on spoke until StorageCluster hop %s completes (ocs-client webhook)\n' \
                "${subName}" "${hopChannel}" >&2
            continue
        fi
        printf 'INFO: Patching subscription %s channel %s → %s\n' \
            "${subName}" "${subChannel}" "${hopChannel}" >&2
        oc --kubeconfig="${kubeconfig}" patch subscription.operators.coreos.com "${subName}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            --type merge \
            -p "$(jq -cn --arg ch "${hopChannel}" '{"spec":{"channel":$ch}}')"
    done < <(jq -r '.items[] | [.metadata.name, (.spec.channel // "")] | @tsv' <<<"${subsJson}")
    true
}

# AlignOdfChannelsForHop — ConfigMap first, then Subscriptions, so the operator
# write-back and this step agree on the hop channel. Skips ocs-client-operator;
# AlignOcsClientAfterHop runs that after StorageCluster hop completion.
AlignOdfChannelsForHop() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset fromChannel="${1:?}"; (($#)) && shift
    typeset hopChannel="${1:?}"; (($#)) && shift
    RetargetOdfPkgsConfigMap "${kubeconfig}" "${fromChannel}" "${hopChannel}"
    PatchOdfNamespaceChannels "${kubeconfig}" "${fromChannel}" "${hopChannel}"
    true
}

# RetargetOcsClientPkgsConfigMap — move only the ocs-client-operator pkgs record.
# Called after StorageCluster hop completion, when the client webhook will accept
# the hop channel.
RetargetOcsClientPkgsConfigMap() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset fromChannel="${1:?}"; (($#)) && shift
    typeset hopChannel="${1:?}"; (($#)) && shift
    typeset cmName='' cmJson='' patchJson=''
    [[ "${fromChannel}" == "${hopChannel}" ]] && return 0
    cmName="$(OdfPkgsConfigMapName "${kubeconfig}")" || return $?
    cmJson="$(oc --kubeconfig="${kubeconfig}" get configmap "${cmName}" \
        -n "${ODF_INSTALL_NAMESPACE}" -o json)" || return $?
    patchJson="$(jq -c --arg from "${fromChannel}" --arg to "${hopChannel}" '
        def retarget:
            split("\n")
            | map(if . == ("channel: " + $from) then "channel: " + $to else . end)
            | join("\n");
        (.data // {})
        | with_entries(select(
            (.key == "OCS_CLIENT")
            or ((.value | split("\n") | index("pkg: ocs-client-operator")) != null)
          ))
        | with_entries(select(.value | split("\n") | index("channel: " + $from)))
        | with_entries(.value |= retarget)
        | if . == {} then empty else {data: .} end
    ' <<<"${cmJson}")" || return $?
    if [[ -z "${patchJson}" ]]; then
        printf 'INFO: ConfigMap %s has no ocs-client-operator channel %s record\n' \
            "${cmName}" "${fromChannel}" >&2
        return 0
    fi
    printf 'INFO: Retargeting ConfigMap %s ocs-client-operator channel %s → %s\n' \
        "${cmName}" "${fromChannel}" "${hopChannel}" >&2
    oc --kubeconfig="${kubeconfig}" patch configmap "${cmName}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --type merge \
        -p "${patchJson}" || return $?
    true
}

# TryAlignOcsClientForHop — one attempt to move ocs-client-operator to hopChannel.
# Returns 0 when every client subscription is already on hopChannel or was patched.
# A webhook Forbidden means StorageClient still pins the previous channel.
TryAlignOcsClientForHop() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset fromChannel="${1:?}"; (($#)) && shift
    typeset hopChannel="${1:?}"; (($#)) && shift
    typeset subsJson='' subName='' subChannel=''
    typeset -i fnRc=0 patchRc=0
    [[ "${fromChannel}" == "${hopChannel}" ]] && return 0
    # Capture status explicitly: this function is called from `if` / `||`, where
    # bash ignores errexit for the whole body.
    {
        RetargetOcsClientPkgsConfigMap "${kubeconfig}" "${fromChannel}" "${hopChannel}" || return $?
        subsJson="$(oc --kubeconfig="${kubeconfig}" get subscription.operators.coreos.com \
            -n "${ODF_INSTALL_NAMESPACE}" -o json)" || return $?
        while IFS=$'\t' read -r subName subChannel; do
            [[ -n "${subName}" ]] || continue
            [[ "${subName}" == *ocs-client-operator* ]] || continue
            [[ "${subChannel}" == "${hopChannel}" ]] && continue
            printf 'INFO: Patching ocs-client-operator subscription %s channel %s → %s\n' \
                "${subName}" "${subChannel}" "${hopChannel}" >&2
            patchRc=0
            oc --kubeconfig="${kubeconfig}" patch subscription.operators.coreos.com "${subName}" \
                -n "${ODF_INSTALL_NAMESPACE}" \
                --type merge \
                -p "$(jq -cn --arg ch "${hopChannel}" '{"spec":{"channel":$ch}}')" \
                || patchRc=$?
            (( patchRc == 0 )) || return "${patchRc}"
        done < <(jq -r '.items[] | [.metadata.name, (.spec.channel // "")] | @tsv' <<<"${subsJson}")
        true
    } || fnRc=$?
    return "${fnRc}"
}

# AlignOcsClientAfterHop — wait until StorageClient annotations allow the hop
# channel, then patch ocs-client-operator. Official ODF upgrades only change
# odf-operator; the provider updates StorageClient desired-subscription-channel
# after the StorageCluster hop, and webhook subscription.ocs.openshift.io
# forbids moving the client earlier.
# https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.22/html/updating_openshift_data_foundation/updating-ocs-to-odf_rhodf
AlignOcsClientAfterHop() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift
    typeset fromChannel="${1:?}"; (($#)) && shift
    typeset hopChannel="${1:?}"; (($#)) && shift
    printf 'INFO: Aligning ocs-client-operator on %s to %s after StorageCluster hop\n' \
        "${clusterName}" "${hopChannel}" >&2
    (
        SECONDS=0
        while (( SECONDS < odfCsvPollMax )); do
            if TryAlignOcsClientForHop "${kubeconfig}" "${fromChannel}" "${hopChannel}"; then
                break
            fi
            : "Waiting for StorageClient on ${clusterName} to allow ocs-client-operator channel ${hopChannel} (${SECONDS}/${odfCsvPollMax}s)"
            sleep "${odfCsvPollInt}"
        done
        TryAlignOcsClientForHop "${kubeconfig}" "${fromChannel}" "${hopChannel}" \
            || { printf 'FATAL: ocs-client-operator on %s could not move to %s within %ss (webhook still pinning StorageClient)\n' "${clusterName}" "${hopChannel}" "${odfCsvPollMax}" >&2; false; }
        true
    )
}

# UpgradeOdfOnSpoke — upgrade ODF on one spoke through all channel hops; writes 0/1 to resultFile.
UpgradeOdfOnSpoke() {
    typeset clusterName="${1:?}"; (($#)) && shift
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset resultFile="${1:?}"; (($#)) && shift
    typeset previousCsv='' hopChannel='' fromChannel='' preDesiredCeph=''
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
            fromChannel="$(oc --kubeconfig="${kubeconfig}" \
                get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
                -n "${ODF_INSTALL_NAMESPACE}" \
                -o jsonpath='{.spec.channel}')"
            [[ -n "${fromChannel}" ]] \
                || { printf 'FATAL: odf-operator subscription on %s has no spec.channel\n' "${clusterName}" >&2; false; }
            printf 'INFO: Spoke %s ODF hop → %s (from channel=%s installedCSV=%s preDesiredCeph=%s)\n' \
                "${clusterName}" "${hopChannel}" "${fromChannel}" "${previousCsv:-<none>}" "${preDesiredCeph:-<none>}" >&2
            AlignOdfChannelsForHop "${kubeconfig}" "${fromChannel}" "${hopChannel}"
            WaitCsvUpgraded "${kubeconfig}" "${previousCsv}" "${clusterName}" "${hopChannel}" "${fromChannel}"
            # Record new CSV as baseline for the next hop before checking StorageCluster.
            previousCsv="$(oc --kubeconfig="${kubeconfig}" \
                get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
                -n "${ODF_INSTALL_NAMESPACE}" \
                -o jsonpath='{.status.installedCSV}' || true)"
            : "Spoke ${clusterName} ODF hop to ${hopChannel} CSV installed: ${previousCsv}"
            WaitStorageClusterAndNoobaaReady "${kubeconfig}" "${clusterName}" "${hopChannel}" "${preDesiredCeph}"
            AlignOcsClientAfterHop "${kubeconfig}" "${clusterName}" "${fromChannel}" "${hopChannel}"
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
(( ${#clusterNamesArr[@]} >= 1 )) \
    || { printf 'FATAL: no spoke cluster names found in %s\n' "${SHARED_DIR}" >&2; false; }

typeset -a spokeKubeconfigsArr=()
mapfile -t spokeKubeconfigsArr < <(LoadSpokeKubeconfigs "${clusterNamesArr[@]}")
(( ${#spokeKubeconfigsArr[@]} == ${#clusterNamesArr[@]} )) \
    || { printf 'FATAL: spoke kubeconfig count (%d) does not match cluster count (%d)\n' \
        "${#spokeKubeconfigsArr[@]}" "${#clusterNamesArr[@]}" >&2; false; }

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
