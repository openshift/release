#!/bin/bash
#
# Install ODF on one or more ACM spoke clusters (redhat-operators path).
# Based on vm_mig_poc/final-odf-install.sh; reads spoke kubeconfigs from SHARED_DIR.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/f63f1f606b1d76f6ef2a3e78b4ec1ad7362d4fac/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

# ODF_SPOKE_OPERATOR_CHANNEL takes precedence over ODF_OPERATOR_CHANNEL.
# This decouples the hub channel (ODF_OPERATOR_CHANNEL) from the spoke channel when hub and
# spoke run different OCP versions (e.g. hub=4.22, spoke starts at 4.21).
ODF_OPERATOR_CHANNEL="${ODF_SPOKE_OPERATOR_CHANNEL:-${ODF_OPERATOR_CHANNEL}}"

typeset -i odfCsvPollInt="${ODF_CSV_POLL_INTERVAL_SECONDS}"
typeset -i odfCsvPollMax="${ODF_CSV_POLL_TIMEOUT_SECONDS}"
typeset -i odfScPollMax="${ODF_STORAGECLUSTER_POLL_TIMEOUT_SECONDS}"
typeset -i odfOcsOperatorBuffer="${ODF_OCS_OPERATOR_BUFFER_SECONDS}"
typeset -i odfPkgPollInt="${ODF_PACKAGE_MANIFEST_POLL_INTERVAL_SECONDS}"
typeset -i odfPkgPollMax="${ODF_PACKAGE_MANIFEST_POLL_TIMEOUT_SECONDS}"
typeset -i odfMonAzStuck="${ODF_MON_AZ_STUCK_SECONDS}"
typeset -i odfMonAzPoll="${ODF_MON_AZ_POLL_INTERVAL_SECONDS}"

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
    oc --kubeconfig="${kubeconfig}" get pvc -n "${ODF_INSTALL_NAMESPACE}" -o wide \
        > "${artifactDir}/odf-pvcs.txt" 2>&1 || true
    oc --kubeconfig="${kubeconfig}" get pvc -n "${ODF_INSTALL_NAMESPACE}" -o json \
        > "${artifactDir}/odf-pvcs.json" || true
    oc --kubeconfig="${kubeconfig}" get pods -n "${ODF_INSTALL_NAMESPACE}" -o wide \
        > "${artifactDir}/odf-pods.txt" 2>&1 || true
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

# ApplyStorageCluster — create/update the spoke StorageCluster CR (idempotent).
ApplyStorageCluster() {
    typeset kubeconfig="${1:?}"

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
}

# GetMonPvcJson — mon PVC list (name/phase/volume/node) for AZ diversity checks.
GetMonPvcJson() {
    typeset kubeconfig="${1:?}"

    oc --kubeconfig="${kubeconfig}" get pvc -n "${ODF_INSTALL_NAMESPACE}" -o json |
        jq -c '
            [
              .items[]
              | select(
                  (.metadata.name | test("^rook-ceph-mon"))
                  or ((.metadata.labels.app // "") == "rook-ceph-mon")
                )
              | {
                  name: .metadata.name,
                  phase: (.status.phase // "Unknown"),
                  volume: (.spec.volumeName // ""),
                  node: (
                    .metadata.annotations["volume.kubernetes.io/selected-node"] // ""
                  )
                }
            ]
        '
}

# ResolvePvZone — topology zone for a bound PV (empty if unresolved).
ResolvePvZone() {
    typeset kubeconfig="${1:?}"
    typeset pvName="${2:?}"
    typeset zone=""

    [[ -n "${pvName}" ]] || { printf ''; return 0; }

    zone="$(oc --kubeconfig="${kubeconfig}" get pv "${pvName}" -o json | jq -r '
        (
          .spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]?
          | select(.key == "topology.kubernetes.io/zone")
          | .values[0]
        ) // (
          .metadata.labels["topology.kubernetes.io/zone"]
        ) // empty
    ' | head -n 1 || true)"
    printf '%s' "${zone}"
}

# ResolveNodeZone — zone label for a node name.
ResolveNodeZone() {
    typeset kubeconfig="${1:?}"
    typeset nodeName="${2:?}"

    [[ -n "${nodeName}" ]] || { printf ''; return 0; }
    oc --kubeconfig="${kubeconfig}" get node "${nodeName}" \
        -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' || true
}

# AnalyzeMonPvcAz — prints: pendingCount boundCount distinctZones hasDuplicateAz
# Example: 1 2 1 true
AnalyzeMonPvcAz() {
    typeset kubeconfig="${1:?}"
    typeset monJson='' name='' phase='' volume='' node='' zone=''
    typeset -i pendingCount=0 boundCount=0
    typeset -A zoneMap=()
    typeset -a zoneArr=()

    monJson="$(GetMonPvcJson "${kubeconfig}")"
    while IFS=$'\t' read -r name phase volume node; do
        [[ -n "${name}" ]] || continue
        if [[ "${phase}" != "Bound" ]]; then
            ((++pendingCount)) || true
            continue
        fi
        ((++boundCount)) || true
        zone="$(ResolvePvZone "${kubeconfig}" "${volume}")"
        if [[ -z "${zone}" && -n "${node}" ]]; then
            zone="$(ResolveNodeZone "${kubeconfig}" "${node}")"
        fi
        [[ -n "${zone}" ]] || continue
        if [[ -z "${zoneMap[${zone}]+x}" ]]; then
            zoneMap["${zone}"]=1
            zoneArr+=("${zone}")
        else
            zoneMap["${zone}"]=$((zoneMap["${zone}"] + 1))
        fi
    done < <(jq -r '.[] | [.name, .phase, .volume, .node] | @tsv' 0<<<"${monJson}")

    typeset hasDuplicateAz='false'
    typeset z=
    for z in "${zoneArr[@]+"${zoneArr[@]}"}"; do
        if (( zoneMap["${z}"] > 1 )); then
            hasDuplicateAz='true'
            break
        fi
    done

    printf '%d %d %d %s' "${pendingCount}" "${boundCount}" "${#zoneArr[@]}" "${hasDuplicateAz}"
}

# RemediateMonAzCollision — one-shot recovery for gp3-csi same-AZ mon binding.
# Prefer deleting Pending mon PVCs; if none Pending, recreate StorageCluster.
RemediateMonAzCollision() {
    typeset kubeconfig="${1:?}"
    typeset monJson="" pendingNames=""

    monJson="$(GetMonPvcJson "${kubeconfig}")"
    pendingNames="$(jq -r '.[] | select(.phase != "Bound") | .name' 0<<<"${monJson}" || true)"

    if [[ -n "${pendingNames}" ]]; then
        : "Remediating mon AZ collision by deleting Pending mon PVC(s): ${pendingNames//$'\n'/ }"
        while IFS= read -r pvcName; do
            [[ -n "${pvcName}" ]] || continue
            oc --kubeconfig="${kubeconfig}" delete pvc "${pvcName}" \
                -n "${ODF_INSTALL_NAMESPACE}" --wait=false
        done <<<"${pendingNames}"
        return 0
    fi

    : "Remediating mon AZ collision by recreating StorageCluster ${ODF_STORAGE_CLUSTER_NAME}"
    oc --kubeconfig="${kubeconfig}" annotate "storagecluster/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        uninstall.ocs.openshift.io/cleanup-policy=delete \
        uninstall.ocs.openshift.io/mode=graceful \
        --overwrite || true
    oc --kubeconfig="${kubeconfig}" delete "storagecluster/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" --wait=true --timeout=10m || true
    # Wait until the CR and mon PVCs are gone before recreate.
    oc --kubeconfig="${kubeconfig}" wait "storagecluster/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" --for=delete --timeout=5m || true
    oc --kubeconfig="${kubeconfig}" wait pvc -n "${ODF_INSTALL_NAMESPACE}" \
        -l app=rook-ceph-mon --for=delete --timeout=2m || true
    ApplyStorageCluster "${kubeconfig}"
}

# AssertStorageClusterReady — hard-fail unless StorageCluster phase is Ready.
AssertStorageClusterReady() {
    typeset kubeconfig="${1:?}"
    typeset phase=""

    phase="$(oc --kubeconfig="${kubeconfig}" get "storagecluster/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        -o jsonpath='{.status.phase}')"
    [[ "${phase}" == "Ready" ]]
}

# HasKubeVirtCrd — true when CNV/KubeVirt CRD is registered on the spoke.
HasKubeVirtCrd() {
    typeset kubeconfig="${1:?}"
    oc --kubeconfig="${kubeconfig}" get crd virtualmachines.kubevirt.io 1>/dev/null
}

# AssertOdfInstallSuccess — post-Ready assertions before declaring spoke ODF success.
AssertOdfInstallSuccess() {
    typeset kubeconfig="${1:?}"

    AssertStorageClusterReady "${kubeconfig}"

    # Virt SC is only created after the KubeVirt CRD exists. If CNV is already on the
    # spoke (hub-spoke / CNV-before-ODF paths), require the virt SC now.
    if HasKubeVirtCrd "${kubeconfig}"; then
        oc --kubeconfig="${kubeconfig}" get storageclass "${ODF_DEFAULT_STORAGE_CLASS}" 1>/dev/null
    else
        : "KubeVirt CRD absent; virt StorageClass ${ODF_DEFAULT_STORAGE_CLASS} not required yet"
    fi
}

# WaitStorageClusterAndNoobaaReady — wait for StorageCluster + NooBaa Ready.
# Bounded mon PVC AZ diversity check first (gp3-csi WaitForFirstConsumer can bind two
# mon PVCs into one AZ and leave the third Pending forever). Then oc wait for
# StorageCluster phase=Ready. Do not reset caller SECONDS — track elapsed locally.
WaitStorageClusterAndNoobaaReady() {
    typeset kubeconfig="${1:?}"
    typeset phase=""
    typeset -i pendingCount=0 boundCount=0 distinctZones=0
    typeset hasDuplicateAz='false'
    typeset -i remediated=0
    typeset -i stuckSince=-1
    typeset -i startSec="${SECONDS}"
    typeset -i elapsed=0
    typeset -i remaining=0
    typeset analysis=""

    : "Mon AZ diversity checks (bounded) before StorageCluster Ready wait"
    while (( (elapsed = SECONDS - startSec) < odfScPollMax )); do
        phase="$(oc --kubeconfig="${kubeconfig}" get "storagecluster/${ODF_STORAGE_CLUSTER_NAME}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            -o jsonpath='{.status.phase}' || true)"
        if [[ "${phase}" == "Ready" ]]; then
            break
        fi

        analysis="$(AnalyzeMonPvcAz "${kubeconfig}")"
        read -r pendingCount boundCount distinctZones hasDuplicateAz <<<"${analysis:-0 0 0 false}"
        : "StorageCluster phase=${phase:-unknown} mons pending=${pendingCount} bound=${boundCount} distinctAz=${distinctZones} duplicateAz=${hasDuplicateAz} (${elapsed}/${odfScPollMax}s)"

        if [[ "${hasDuplicateAz}" == "true" ]] && (( pendingCount > 0 )); then
            if (( stuckSince < 0 )); then
                stuckSince="${elapsed}"
            fi
            if (( remediated == 0 && (elapsed - stuckSince) >= odfMonAzStuck )); then
                RemediateMonAzCollision "${kubeconfig}"
                remediated=1
                stuckSince="${elapsed}"
            fi
        else
            stuckSince=-1
        fi

        sleep "${odfMonAzPoll}"
    done

    if [[ "${phase}" != "Ready" ]]; then
        remaining=$(( odfScPollMax - (SECONDS - startSec) ))
        (( remaining < 1 )) && remaining=1
        : "Waiting for StorageCluster phase=Ready (remaining ${remaining}s)"
        oc --kubeconfig="${kubeconfig}" wait \
            "storagecluster/${ODF_STORAGE_CLUSTER_NAME}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            --for=jsonpath='{.status.phase}'=Ready \
            --timeout="${remaining}s"
    fi

    # Assert phase explicitly so a timed-out wait cannot be masked later.
    AssertStorageClusterReady "${kubeconfig}"

    : "Waiting for NooBaa phase=Ready"
    oc --kubeconfig="${kubeconfig}" wait \
        noobaa/noobaa \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s"
    typeset noobaaPhase=""
    noobaaPhase="$(oc --kubeconfig="${kubeconfig}" get noobaa/noobaa \
        -n "${ODF_INSTALL_NAMESPACE}" \
        -o jsonpath='{.status.phase}')"
    [[ "${noobaaPhase}" == "Ready" ]]
}

# ConfigureDefaultStorage — set virtualization SC and snapshot class as cluster defaults.
# When ODF_DEFAULT_STORAGE_CLASS ends in -ceph-rbd-virtualization the SC only exists after
# the KubeVirt virtualmachines.kubevirt.io CRD is registered (by CNV) AND StorageCluster is
# Ready. Distinguish "CNV absent" vs "ODF not Ready" so logs are not misleading.
ConfigureDefaultStorage() {
    typeset kubeconfig="${1:?}"
    typeset scName="" scPhase=""

    if [[ "${ODF_DEFAULT_STORAGE_CLASS}" == *-ceph-rbd-virtualization ]] && \
       ! oc --kubeconfig="${kubeconfig}" get storageclass "${ODF_DEFAULT_STORAGE_CLASS}" 1>/dev/null; then
        scPhase="$(oc --kubeconfig="${kubeconfig}" get "storagecluster/${ODF_STORAGE_CLUSTER_NAME}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            -o jsonpath='{.status.phase}' || true)"
        if ! HasKubeVirtCrd "${kubeconfig}"; then
            : "Virt StorageClass ${ODF_DEFAULT_STORAGE_CLASS} absent: KubeVirt CRD not registered (CNV not installed yet); skipping default annotation — later CNV/ODF reconcile will create it"
            return 0
        fi
        if [[ "${scPhase}" != "Ready" ]]; then
            : "Virt StorageClass ${ODF_DEFAULT_STORAGE_CLASS} absent: StorageCluster phase=${scPhase:-unknown} (ODF not Ready yet); refusing success"
            false
        fi
        : "Virt StorageClass ${ODF_DEFAULT_STORAGE_CLASS} absent despite CNV CRD + StorageCluster Ready"
        false
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
# Critical: do NOT put the install body on the LHS of `cmd || handler`.
# With `set -e`, errexit is disabled in the left-hand side of `||`, so a timed-out
# `oc wait` can be ignored and a later successful command makes the subshell exit 0
# (false PASS). Use `if ! ( set -euxo pipefail; ... ); then ...; fi` instead.
InstallOdfOnSpoke() {
    typeset clusterName="${1:?}"
    typeset kubeconfig="${2:?}"
    typeset resultFile="${3:?}"
    typeset startingCsv="" ogName=""
    typeset targetOgName="${ODF_INSTALL_NAMESPACE}-operatorgroup"

    if ! (
        set -euxo pipefail; shopt -s inherit_errexit

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

        oc --kubeconfig="${kubeconfig}" wait --for=create \
            deployment/ocs-operator \
            -n "${ODF_INSTALL_NAMESPACE}" \
            --timeout="${odfOcsOperatorBuffer}s"
        oc --kubeconfig="${kubeconfig}" wait deployment/ocs-operator \
            -n "${ODF_INSTALL_NAMESPACE}" \
            --for=condition=Available \
            --timeout=5m

        oc --kubeconfig="${kubeconfig}" label nodes cluster.ocs.openshift.io/openshift-storage='' \
            --selector='node-role.kubernetes.io/worker' \
            --overwrite

        # Verify every worker node received the ODF storage label.
        # ODF schedules OSDs only onto labeled nodes; a mismatch means at least one worker
        # was silently skipped and the StorageCluster will fail to reach Ready.
        typeset -i _workerCount _labeledCount
        _workerCount="$(oc --kubeconfig="${kubeconfig}" get nodes \
            --selector='node-role.kubernetes.io/worker' \
            -o json | jq '.items | length')"
        _labeledCount="$(oc --kubeconfig="${kubeconfig}" get nodes \
            --selector='cluster.ocs.openshift.io/openshift-storage' \
            -o json | jq '.items | length')"
        : "ODF storage label check: ${_labeledCount}/${_workerCount} worker nodes labeled on ${clusterName}"
        (( _workerCount > 0 && _labeledCount == _workerCount ))

        oc --kubeconfig="${kubeconfig}" wait --for=create crd/storageclusters.ocs.openshift.io \
            --timeout=5m

        ApplyStorageCluster "${kubeconfig}"

        WaitStorageClusterAndNoobaaReady "${kubeconfig}"
        ConfigureDefaultStorage "${kubeconfig}"
        AssertOdfInstallSuccess "${kubeconfig}"

        oc --kubeconfig="${kubeconfig}" get storagecluster,storageclass \
            -n "${ODF_INSTALL_NAMESPACE}" \
            > "${ARTIFACT_DIR}/odf-spoke-${clusterName}-status.txt"
        printf '0' > "${resultFile}"
    ); then
        DumpSpokeOdfDiagnostics "${clusterName}" "${kubeconfig}"
        printf '1' > "${resultFile}"
        return 1
    fi
    true
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
