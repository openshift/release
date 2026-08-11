#!/bin/bash
#
# Install ODF on one or more ACM spoke clusters (redhat-operators path).
# Based on vm_mig_poc/final-odf-install.sh; reads spoke kubeconfigs from SHARED_DIR.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset -i odfCsvPollInt="${ODF_CSV_POLL_INTERVAL_SECONDS}"
typeset -i odfCsvPollMax="${ODF_CSV_POLL_TIMEOUT_SECONDS}"
typeset -i odfCephPollInt="${ODF_CEPH_POLL_INTERVAL_SECONDS}"
typeset -i odfCephPollMax="${ODF_CEPH_POLL_TIMEOUT_SECONDS}"
typeset -i odfScPollInt="${ODF_STORAGECLUSTER_POLL_INTERVAL_SECONDS}"
typeset -i odfScPollMax="${ODF_STORAGECLUSTER_POLL_TIMEOUT_SECONDS}"
typeset -i odfOcsOperatorBuffer="${ODF_OCS_OPERATOR_BUFFER_SECONDS}"
typeset -i odfCephInitialDelay="${ODF_CEPH_INITIAL_DELAY_SECONDS}"
typeset -i odfPkgPollInt="${ODF_PACKAGE_MANIFEST_POLL_INTERVAL_SECONDS}"
typeset -i odfPkgPollMax="${ODF_PACKAGE_MANIFEST_POLL_TIMEOUT_SECONDS}"

typeset resultsDir=""

# Cleanup — remove temp result directory on EXIT.
Cleanup() {
    [[ -n "${resultsDir}" && -d "${resultsDir}" ]] && rm -rf "${resultsDir}"
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

    ((${#clusterNamesArr[@]} >= 1))
    printf '%s\n' "${clusterNamesArr[@]}"
}

# LoadSpokeKubeconfigs — resolve per-spoke kubeconfig paths aligned with clusterNamesArr.
LoadSpokeKubeconfigs() {
    typeset -a clusterNamesArr=("${@}")
    typeset -a spokeKubeconfigsArr=()
    typeset -i kcIdx idx
    typeset kcFile=""

    for ((kcIdx = 0; kcIdx < ${#clusterNamesArr[@]}; kcIdx++)); do
        idx=$((kcIdx + 1))
        kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${idx}"

        if [[ ! -f "${kcFile}" && ${#clusterNamesArr[@]} -eq 1 ]]; then
            kcFile="${SHARED_DIR}/managed-cluster-kubeconfig"
        fi

        [[ -f "${kcFile}" ]]
        spokeKubeconfigsArr+=("${kcFile}")
    done

    printf '%s\n' "${spokeKubeconfigsArr[@]}"
}

# DumpSpokeOdfDiagnostics — write non-secret cluster state and ODF must-gather to ARTIFACT_DIR on failure.
DumpSpokeOdfDiagnostics() {
    typeset clusterName="${1:?}"
    typeset kubeconfig="${2:?}"
    typeset artifactDir="${ARTIFACT_DIR}/odf-spoke-${clusterName}"
    typeset odfVersion="${ODF_OPERATOR_CHANNEL#stable-}"

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
}

# ResolveStartingCsv — look up channel head CSV from packagemanifest on the spoke.
ResolveStartingCsv() {
    typeset kubeconfig="${1:?}"
    typeset startingCsv=""

    (
        SECONDS=0
        while (( SECONDS < odfPkgPollMax )); do
            startingCsv="$(oc --kubeconfig="${kubeconfig}" get packagemanifest odf-operator \
                -n openshift-marketplace \
                -o jsonpath="{.status.channels[?(@.name==\"${ODF_OPERATOR_CHANNEL}\")].currentCSVName}" \
                || true)"
            [[ -n "${startingCsv}" ]] && break
            : "Waiting for odf-operator packagemanifest (${SECONDS}/${odfPkgPollMax}s)"
            sleep "${odfPkgPollInt}"
        done
        [[ -n "${startingCsv}" ]]
        printf '%s' "${startingCsv}"
    )
}

# WaitCsvSucceeded — poll until Subscription installedCSV reaches Succeeded phase.
WaitCsvSucceeded() {
    typeset kubeconfig="${1:?}"
    typeset csvName="" csvPhase=""

    (
        SECONDS=0
        while (( SECONDS < odfCsvPollMax )); do
            csvName="$(oc --kubeconfig="${kubeconfig}" get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
                -n "${ODF_INSTALL_NAMESPACE}" \
                -o jsonpath='{.status.installedCSV}' || true)"
            if [[ -n "${csvName}" ]]; then
                csvPhase="$(oc --kubeconfig="${kubeconfig}" get csv "${csvName}" \
                    -n "${ODF_INSTALL_NAMESPACE}" \
                    -o jsonpath='{.status.phase}' || true)"
                [[ "${csvPhase}" == "Succeeded" ]] && break
            fi
            : "Waiting for ODF CSV Succeeded (${SECONDS}/${odfCsvPollMax}s, csv=${csvName:-pending})"
            sleep "${odfCsvPollInt}"
        done
        [[ "${csvPhase}" == "Succeeded" ]]
        true
    )
}

# WaitCephClusterReady — poll first CephCluster until phase Ready.
WaitCephClusterReady() {
    typeset kubeconfig="${1:?}"
    typeset cephPhase=""

    sleep "${odfCephInitialDelay}"
    (
        SECONDS=0
        while (( SECONDS < odfCephPollMax )); do
            cephPhase="$(oc --kubeconfig="${kubeconfig}" get cephcluster -n "${ODF_INSTALL_NAMESPACE}" \
                -o jsonpath='{.items[0].status.phase}' || true)"
            [[ "${cephPhase}" == "Ready" ]] && break
            : "Waiting for CephCluster Ready (${SECONDS}/${odfCephPollMax}s, phase=${cephPhase:-unknown})"
            sleep "${odfCephPollInt}"
        done
        [[ "${cephPhase}" == "Ready" ]]
        true
    )
}

# WaitStorageClusterAndNoobaaReady — poll StorageCluster phase and NooBaa until both Ready.
WaitStorageClusterAndNoobaaReady() {
    typeset kubeconfig="${1:?}"
    typeset scPhase="" noobaaPhase=""

    (
        SECONDS=0
        while (( SECONDS < odfScPollMax )); do
            scPhase="$(oc --kubeconfig="${kubeconfig}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
                -n "${ODF_INSTALL_NAMESPACE}" \
                -o jsonpath='{.status.phase}' || true)"
            noobaaPhase="$(oc --kubeconfig="${kubeconfig}" get noobaa noobaa \
                -n "${ODF_INSTALL_NAMESPACE}" \
                -o jsonpath='{.status.phase}' || true)"
            if [[ "${scPhase}" == "Ready" && "${noobaaPhase}" == "Ready" ]]; then
                break
            fi
            : "Waiting for StorageCluster/NooBaa Ready (${SECONDS}/${odfScPollMax}s, sc=${scPhase:-unknown}, noobaa=${noobaaPhase:-unknown})"
            sleep "${odfScPollInt}"
        done
        [[ "${scPhase}" == "Ready" && "${noobaaPhase}" == "Ready" ]]
        true
    )
}

# ConfigureDefaultStorage — set virtualization SC and snapshot class as cluster defaults.
# When ODF_DEFAULT_STORAGE_CLASS ends in -ceph-rbd-virtualization the SC only exists after
# the KubeVirt virtualmachines.kubevirt.io CRD is registered (by CNV). If CNV is installed
# after this step (the normal p2p upgrade sequence), the SC will not exist yet — skip the
# annotation here; the subsequent p2p-acm-cnv-install-policy step's ConfigureOdfVirtStorageClassDefaults
# waits for and annotates the virt SC once ODF creates it in response to the KubeVirt CRD.
ConfigureDefaultStorage() {
    typeset kubeconfig="${1:?}"
    typeset scName=""

    if [[ "${ODF_DEFAULT_STORAGE_CLASS}" == *-ceph-rbd-virtualization ]] && \
       ! oc --kubeconfig="${kubeconfig}" get storageclass "${ODF_DEFAULT_STORAGE_CLASS}" 1>/dev/null; then
        : "Virt StorageClass ${ODF_DEFAULT_STORAGE_CLASS} not present yet (CNV not installed); skipping default annotation — will be set by p2p-acm-cnv-install-policy"
        return 0
    fi

    while IFS= read -r scName; do
        [[ -n "${scName}" ]] || continue
        oc --kubeconfig="${kubeconfig}" annotate storageclass "${scName}" \
            storageclass.kubernetes.io/is-default-class- --overwrite 1>/dev/null || true
    done < <(oc --kubeconfig="${kubeconfig}" get sc -o json | jq -r '.items[].metadata.name')

    oc --kubeconfig="${kubeconfig}" annotate storageclass "${ODF_DEFAULT_STORAGE_CLASS}" \
        storageclass.kubernetes.io/is-default-class=true --overwrite

    while IFS= read -r vscName; do
        [[ -n "${vscName}" ]] || continue
        oc --kubeconfig="${kubeconfig}" annotate "volumesnapshotclass/${vscName}" \
            snapshot.storage.kubernetes.io/is-default-class- --overwrite 1>/dev/null || true
    done < <(oc --kubeconfig="${kubeconfig}" get volumesnapshotclass -o json | jq -r '.items[].metadata.name' || true)

    oc --kubeconfig="${kubeconfig}" annotate volumesnapshotclass "${ODF_SNAPSHOT_CLASS}" \
        snapshot.storage.kubernetes.io/is-default-class=true --overwrite 1>/dev/null || true

    oc --kubeconfig="${kubeconfig}" rollout restart deployment/csi-snapshot-controller \
        -n openshift-cluster-storage-operator 1>/dev/null || true
}

# InstallOdfOnSpoke — full ODF install on one spoke; writes 0/1 to resultFile.
InstallOdfOnSpoke() {
    typeset clusterName="${1:?}"
    typeset kubeconfig="${2:?}"
    typeset resultFile="${3:?}"
    typeset startingCsv="" ogName=""
    typeset targetOgName="${ODF_INSTALL_NAMESPACE}-operatorgroup"

    (
        # Namespace: oc create namespace gives backward/forward API version compatibility.
        oc --kubeconfig="${kubeconfig}" create namespace "${ODF_INSTALL_NAMESPACE}" \
            --dry-run=client -o yaml --save-config | oc --kubeconfig="${kubeconfig}" apply -f -

        # Delete any pre-existing OperatorGroup that is NOT our target. OLM rejects multiple
        # OperatorGroups per namespace, so a conflicting leftover from a prior run must be removed
        # before we apply ours. Skipping the target means re-runs do not destroy an existing OG.
        while IFS= read -r ogName; do
            [[ -n "${ogName}" ]] || continue
            [[ "${ogName}" == "${targetOgName}" ]] && continue
            oc --kubeconfig="${kubeconfig}" delete operatorgroup "${ogName}" \
                -n "${ODF_INSTALL_NAMESPACE}" --ignore-not-found 1>/dev/null
        done < <(oc --kubeconfig="${kubeconfig}" get operatorgroup -n "${ODF_INSTALL_NAMESPACE}" \
            -o json | jq -r '.items[].metadata.name' || true)

        # OperatorGroup: jq marshals all variable values into JSON; oc apply is idempotent.
        jq -cn \
            --arg name "${targetOgName}" \
            --arg ns "${ODF_INSTALL_NAMESPACE}" \
            '{
                apiVersion: "operators.coreos.com/v1",
                kind: "OperatorGroup",
                metadata: {name: $name, namespace: $ns},
                spec: {targetNamespaces: [$ns]}
            }' | oc --kubeconfig="${kubeconfig}" apply -f -

        startingCsv="$(ResolveStartingCsv "${kubeconfig}" || true)"

        # Subscription: jq marshals all values and conditionally sets startingCSV.
        # No CSV pre-deletion — oc apply is idempotent; deleting a live CSV would break ODF on re-run.
        jq -cn \
            --arg channel "${ODF_OPERATOR_CHANNEL}" \
            --arg name "${ODF_SUBSCRIPTION_NAME}" \
            --arg ns "${ODF_INSTALL_NAMESPACE}" \
            --arg csv "${startingCsv}" \
            '{
                apiVersion: "operators.coreos.com/v1alpha1",
                kind: "Subscription",
                metadata: {name: $name, namespace: $ns},
                spec: {
                    channel: $channel,
                    installPlanApproval: "Automatic",
                    name: $name,
                    source: "redhat-operators",
                    sourceNamespace: "openshift-marketplace"
                }
            } | if $csv != "" then .spec.startingCSV = $csv else . end' |
            oc --kubeconfig="${kubeconfig}" apply -f -

        WaitCsvSucceeded "${kubeconfig}"

        sleep "${odfOcsOperatorBuffer}"
        oc --kubeconfig="${kubeconfig}" wait deployment ocs-operator \
            -n "${ODF_INSTALL_NAMESPACE}" \
            --for=condition=Available \
            --timeout=5m

        oc --kubeconfig="${kubeconfig}" label nodes cluster.ocs.openshift.io/openshift-storage='' \
            --selector='node-role.kubernetes.io/worker' \
            --overwrite

        oc --kubeconfig="${kubeconfig}" wait --for=create crd/storageclusters.ocs.openshift.io \
            --timeout=5m

        # StorageCluster: jq marshals all variable values into JSON; oc apply is idempotent.
        jq -cn \
            --arg scName "${ODF_STORAGE_CLUSTER_NAME}" \
            --arg ns "${ODF_INSTALL_NAMESPACE}" \
            --arg backendSc "${ODF_BACKEND_STORAGE_CLASS}" \
            --arg size "${ODF_VOLUME_SIZE}" \
            '{
                apiVersion: "ocs.openshift.io/v1",
                kind: "StorageCluster",
                metadata: {
                    name: $scName,
                    namespace: $ns,
                    annotations: {
                        "uninstall.ocs.openshift.io/cleanup-policy": "delete",
                        "uninstall.ocs.openshift.io/mode": "graceful"
                    }
                },
                spec: {
                    resourceProfile: "balanced",
                    managedResources: {cephBlockPools: {
                        defaultStorageClass: true,
                        defaultVirtualizationStorageClass: true
                    }},
                    storageDeviceSets: [{
                        name: ("ocs-deviceset-" + $backendSc),
                        count: 1,
                        replica: 3,
                        portable: true,
                        deviceClass: "ssd",
                        resources: {},
                        placement: {},
                        dataPVCTemplate: {spec: {
                            accessModes: ["ReadWriteOnce"],
                            resources: {requests: {storage: $size}},
                            storageClassName: $backendSc,
                            volumeMode: "Block"
                        }}
                    }]
                }
            }' | oc --kubeconfig="${kubeconfig}" apply -f -

        WaitCephClusterReady "${kubeconfig}"
        WaitStorageClusterAndNoobaaReady "${kubeconfig}"
        ConfigureDefaultStorage "${kubeconfig}"

        oc --kubeconfig="${kubeconfig}" get storagecluster,storageclass \
            -n "${ODF_INSTALL_NAMESPACE}" \
            > "${ARTIFACT_DIR}/odf-spoke-${clusterName}-status.txt"
        printf '0' > "${resultFile}"
        true
    ) || {
        DumpSpokeOdfDiagnostics "${clusterName}" "${kubeconfig}"
        printf '1' > "${resultFile}"
        false
    }
}

typeset -a clusterNamesArr=()
mapfile -t clusterNamesArr < <(LoadSpokeClusterNames)

typeset -a spokeKubeconfigsArr=()
mapfile -t spokeKubeconfigsArr < <(LoadSpokeKubeconfigs "${clusterNamesArr[@]}")

resultsDir="$(mktemp -d "${ARTIFACT_DIR}/odf-spoke-install.XXXXXX")"

typeset -i failedCount=0 idx waitRc=0
typeset resultFile="" storedRc=""

if (( ${#clusterNamesArr[@]} == 1 )); then
    # Single spoke: call directly to avoid background subprocess overhead.
    resultFile="${resultsDir}/cluster-1.result"
    InstallOdfOnSpoke "${clusterNamesArr[0]}" "${spokeKubeconfigsArr[0]}" "${resultFile}" || true
    storedRc="$(<"${resultFile}")"
    [[ "${storedRc}" == "0" ]] || failedCount=1
else
    # Multiple spokes: install in parallel so total wall-clock time is ~1x per-spoke
    # rather than N x per-spoke (each ODF install takes ~60-90 min).
    typeset -a pidsArr=()
    for ((idx = 0; idx < ${#clusterNamesArr[@]}; idx++)); do
        resultFile="${resultsDir}/cluster-$((idx + 1)).result"
        InstallOdfOnSpoke "${clusterNamesArr[idx]}" "${spokeKubeconfigsArr[idx]}" "${resultFile}" &
        pidsArr+=($!)
    done

    for ((idx = 0; idx < ${#pidsArr[@]}; idx++)); do
        resultFile="${resultsDir}/cluster-$((idx + 1)).result"
        waitRc=0
        wait "${pidsArr[idx]}" || waitRc=$?

        if [[ -f "${resultFile}" ]]; then
            storedRc="$(<"${resultFile}")"
            [[ "${storedRc}" == "0" ]] || ((++failedCount))
        elif (( waitRc != 0 )); then
            ((++failedCount))
        fi
    done
fi

(( failedCount == 0 ))
true
