#!/bin/bash
#
# Install ODF on the ACM hub cluster using a direct OLM subscription (redhat-operators path).
# Based on p2p-install-odf-spokes; targets the hub cluster via ${KUBECONFIG}.
#
# TODO: Replace this direct OLM subscription approach with an ACM OperatorPolicy/ConfigurationPolicy
# based installation (similar to the OPP policy set) so that ODF on the hub is managed declaratively
# through ACM's policy engine. The policy approach requires: a Policy with an OperatorPolicy for the
# odf-operator Subscription, a ConfigurationPolicy for the StorageCluster, a Placement targeting
# local-cluster, a PlacementBinding, and a ManagedClusterSetBinding for the policies namespace.
# See prior implementation in the OPP policy collection and the stolostron/policy-collection configs.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset -i odfCsvPollInt="${ODF_CSV_POLL_INTERVAL_SECONDS}"
typeset -i odfCsvPollMax="${ODF_CSV_POLL_TIMEOUT_SECONDS}"
typeset -i odfScPollMax="${ODF_STORAGECLUSTER_POLL_TIMEOUT_SECONDS}"
typeset -i odfOcsOperatorBuffer="${ODF_OCS_OPERATOR_BUFFER_SECONDS}"
typeset -i odfPkgPollInt="${ODF_PACKAGE_MANIFEST_POLL_INTERVAL_SECONDS}"
typeset -i odfPkgPollMax="${ODF_PACKAGE_MANIFEST_POLL_TIMEOUT_SECONDS}"

# Derive ODF major.minor from the channel (e.g. stable-4.21 → 4.21) for the must-gather image tag.
typeset odfVersion="${ODF_OPERATOR_CHANNEL#stable-}"

# DumpHubOdfDiagnostics — write non-secret hub ODF state to ARTIFACT_DIR.
# Called via EXIT trap on completion (success and failure).
# NOTE: In ODF 4.21, the CephCluster CR is named "${ODF_STORAGE_CLUSTER_NAME}-cephcluster"
# (e.g. ocs-storagecluster-cephcluster), NOT the same as the StorageCluster name.
DumpHubOdfDiagnostics() {
    typeset artifactDir="${ARTIFACT_DIR}/odf-hub"
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
    oc --kubeconfig="${KUBECONFIG}" get "cephcluster/${ODF_STORAGE_CLUSTER_NAME}-cephcluster" \
        -n "${ODF_INSTALL_NAMESPACE}" -o yaml \
        > "${artifactDir}/cephcluster.yaml" 2>&1 || true
    # CSI chain — critical for StorageClass availability
    oc --kubeconfig="${KUBECONFIG}" get storageclient \
        -n "${ODF_INSTALL_NAMESPACE}" -o wide \
        > "${artifactDir}/storageclient.txt" 2>&1 || true
    oc --kubeconfig="${KUBECONFIG}" get driver.csi.ceph.io \
        -n "${ODF_INSTALL_NAMESPACE}" \
        > "${artifactDir}/csi-drivers.txt" 2>&1 || true
    oc --kubeconfig="${KUBECONFIG}" get storageclass \
        > "${artifactDir}/storageclasses.txt" 2>&1 || true
    oc --kubeconfig="${KUBECONFIG}" get storageconsumer \
        -n "${ODF_INSTALL_NAMESPACE}" -o yaml \
        > "${artifactDir}/storageconsumer.yaml" 2>&1 || true
}
trap '
    typeset _exitCode=$?
    DumpHubOdfDiagnostics
    ((_exitCode)) &&
        oc adm must-gather \
            --image="quay.io/rhceph-dev/ocs-must-gather:latest-${odfVersion}" \
            --dest-dir="${ARTIFACT_DIR}/ocs_must_gather" || true
' EXIT

# ResolveStartingCsv — look up channel head CSV from packagemanifest on the hub.
ResolveStartingCsv() {
    typeset startingCsv=""

    (
        SECONDS=0
        while (( SECONDS < odfPkgPollMax )); do
            startingCsv="$(oc --kubeconfig="${KUBECONFIG}" get packagemanifest odf-operator \
                -n openshift-marketplace \
                -o jsonpath="{.status.channels[?(@.name==\"${ODF_OPERATOR_CHANNEL}\")].currentCSVName}" \
                || true)"
            [[ -n "${startingCsv}" ]] && break
            : "Waiting for odf-operator packagemanifest (${SECONDS}/${odfPkgPollMax}s)"
            # oc wait --for=jsonpath requires an exact value; currentCSVName is unknown
            # before the packagemanifest is populated, so a poll loop is necessary here.
            sleep "${odfPkgPollInt}"
        done
        [[ -n "${startingCsv}" ]]
        printf '%s' "${startingCsv}"
    )
}

# WaitCsvSucceeded — poll until Subscription installedCSV reaches Succeeded phase.
# Uses subscription.operators.coreos.com to avoid ambiguity with ACM subscriptions on the hub.
WaitCsvSucceeded() {
    typeset csvName=""

    (
        SECONDS=0
        while (( SECONDS < odfCsvPollMax )); do
            csvName="$(oc --kubeconfig="${KUBECONFIG}" \
                get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
                -n "${ODF_INSTALL_NAMESPACE}" \
                -o jsonpath='{.status.installedCSV}' || true)"
            [[ -n "${csvName}" ]] && break
            : "Waiting for ODF installedCSV (${SECONDS}/${odfCsvPollMax}s)"
            # oc wait --for=jsonpath requires an exact value; installedCSV name is unknown
            # until OLM resolves it, so a poll loop is necessary here.
            sleep "${odfCsvPollInt}"
        done
        [[ -n "${csvName}" ]]
        oc --kubeconfig="${KUBECONFIG}" wait "clusterserviceversion/${csvName}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            --for=jsonpath='{.status.phase}'=Succeeded \
            --timeout="${odfCsvPollMax}s"
        true
    )
}

# WaitStorageClusterAndNoobaaReady — wait for StorageCluster and NooBaa to both reach Ready.
# StorageCluster phase=Ready is authoritative: it implies the CephCluster was created and
# reached Ready (Ceph health OK, OSDs up) and all ODF sub-resources are reconciled.
#
# There is no explicit CephCluster wait. Root cause from CI failures:
#   In ODF 4.21 the CephCluster CR is named "${ODF_STORAGE_CLUSTER_NAME}-cephcluster"
#   (e.g. "ocs-storagecluster-cephcluster"), NOT the StorageCluster name. All previous
#   attempts waited on "cephcluster/ocs-storagecluster" which never exists. The actual
#   CephCluster was created within ~6 min of StorageCluster apply and reached Ready in ~9 min,
#   but was always looked up under the wrong name.
#
# WaitStorageClusterAndNoobaaReady uses odfScPollMax (5400s = 90 min) and is name-agnostic.
# NooBaa CR is always named "noobaa" by the ODF operator.
WaitStorageClusterAndNoobaaReady() {
    : "Waiting for StorageCluster phase=Ready (covers CephCluster creation + Ceph bootstrap)"
    oc --kubeconfig="${KUBECONFIG}" wait \
        "storagecluster/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s"
    : "Waiting for NooBaa phase=Ready"
    oc --kubeconfig="${KUBECONFIG}" wait \
        noobaa/noobaa \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s"
}

# WaitStorageClassesReady — wait for ODF CSI StorageClasses to be provisioned.
# StorageClasses are created by the CSI driver chain (StorageClient → Driver.csi.ceph.io →
# DaemonSets → StorageClasses). This happens after StorageCluster is Ready but is driven by
# a separate operator chain; an explicit wait prevents ConfigureDefaultStorage from failing
# on a missing StorageClass if the CSI chain is slow.
WaitStorageClassesReady() {
    : "Waiting for ODF StorageClass ${ODF_HUB_DEFAULT_STORAGE_CLASS} to exist"
    oc --kubeconfig="${KUBECONFIG}" wait \
        --for=create "storageclass/${ODF_HUB_DEFAULT_STORAGE_CLASS}" \
        --timeout="${odfScPollMax}s"
    : "Waiting for ODF StorageClass ocs-storagecluster-cephfs to exist"
    oc --kubeconfig="${KUBECONFIG}" wait \
        --for=create storageclass/ocs-storagecluster-cephfs \
        --timeout=5m
}

# ConfigureDefaultStorage — set default StorageClass and VolumeSnapshotClass on the hub.
# Uses ODF_HUB_DEFAULT_STORAGE_CLASS (not ODF_DEFAULT_STORAGE_CLASS) so that the hub is
# unaffected by the job-level ODF_DEFAULT_STORAGE_CLASS=ocs-storagecluster-ceph-rbd-virtualization
# which is consumed by p2p-install-odf-spokes and p2p-acm-cnv-install-policy on the spokes.
# CNV is never installed on the hub, so the virt SC will not exist; always use a SC that ODF
# creates unconditionally (default: ocs-storagecluster-ceph-rbd).
ConfigureDefaultStorage() {
    typeset scName="" vscName=""

    while IFS= read -r scName; do
        [[ -n "${scName}" ]] || continue
        oc --kubeconfig="${KUBECONFIG}" annotate storageclass "${scName}" \
            storageclass.kubernetes.io/is-default-class- --overwrite 1>/dev/null || true
    done < <(oc --kubeconfig="${KUBECONFIG}" get sc -o json | jq -r '.items[].metadata.name')

    oc --kubeconfig="${KUBECONFIG}" annotate storageclass "${ODF_HUB_DEFAULT_STORAGE_CLASS}" \
        storageclass.kubernetes.io/is-default-class=true --overwrite

    while IFS= read -r vscName; do
        [[ -n "${vscName}" ]] || continue
        oc --kubeconfig="${KUBECONFIG}" annotate "volumesnapshotclass/${vscName}" \
            snapshot.storage.kubernetes.io/is-default-class- --overwrite 1>/dev/null || true
    done < <(oc --kubeconfig="${KUBECONFIG}" get volumesnapshotclass -o json \
        | jq -r '.items[].metadata.name' || true)

    oc --kubeconfig="${KUBECONFIG}" annotate volumesnapshotclass "${ODF_HUB_SNAPSHOT_CLASS}" \
        snapshot.storage.kubernetes.io/is-default-class=true --overwrite 1>/dev/null || true

    oc --kubeconfig="${KUBECONFIG}" rollout restart deployment/csi-snapshot-controller \
        -n openshift-cluster-storage-operator 1>/dev/null || true
}

# -- Main -----------------------------------------------------------------------

typeset startingCsv="" ogName=""
typeset targetOgName="${ODF_INSTALL_NAMESPACE}-operatorgroup"

# Namespace: oc create namespace gives backward/forward API version compatibility.
oc --kubeconfig="${KUBECONFIG}" create namespace "${ODF_INSTALL_NAMESPACE}" \
    --dry-run=client -o yaml --save-config | oc --kubeconfig="${KUBECONFIG}" apply -f -

# Delete any pre-existing OperatorGroup that is NOT our target. OLM rejects multiple
# OperatorGroups per namespace, so a conflicting leftover from a prior run must be removed
# before we apply ours. Skipping the target means re-runs do not destroy an existing OG.
while IFS= read -r ogName; do
    [[ -n "${ogName}" ]] || continue
    [[ "${ogName}" == "${targetOgName}" ]] && continue
    oc --kubeconfig="${KUBECONFIG}" delete operatorgroup "${ogName}" \
        -n "${ODF_INSTALL_NAMESPACE}" --ignore-not-found 1>/dev/null
done < <(oc --kubeconfig="${KUBECONFIG}" get operatorgroup -n "${ODF_INSTALL_NAMESPACE}" \
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
    }' | oc --kubeconfig="${KUBECONFIG}" apply -f -

startingCsv="$(ResolveStartingCsv || true)"

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
    oc --kubeconfig="${KUBECONFIG}" apply -f -

WaitCsvSucceeded

oc --kubeconfig="${KUBECONFIG}" wait --for=create \
    deployment/ocs-operator \
    -n "${ODF_INSTALL_NAMESPACE}" \
    --timeout="${odfOcsOperatorBuffer}s"
oc --kubeconfig="${KUBECONFIG}" wait deployment/ocs-operator \
    -n "${ODF_INSTALL_NAMESPACE}" \
    --for=condition=Available \
    --timeout=5m

# Enable the ODF console plugin via the operator Console CR.
# Must use console.operator.openshift.io (not console.config.openshift.io) — only the
# operator CR has spec.plugins; the config CR does not and silently ignores the field.
# Reads existing plugins and appends odf-console idempotently so other plugins are preserved.
typeset _existingPlugins=""
_existingPlugins="$(oc --kubeconfig="${KUBECONFIG}" get console.operator.openshift.io cluster \
    -o jsonpath='{.spec.plugins}' || true)"
[[ -z "${_existingPlugins}" || "${_existingPlugins}" == "null" ]] && _existingPlugins='[]'
oc --kubeconfig="${KUBECONFIG}" patch console.operator.openshift.io cluster \
    --type=merge \
    -p="{\"spec\":{\"plugins\":$(printf '%s' "${_existingPlugins}" | jq -c '. + ["odf-console"] | unique')}}"

oc --kubeconfig="${KUBECONFIG}" label nodes cluster.ocs.openshift.io/openshift-storage='' \
    --selector='node-role.kubernetes.io/worker' \
    --overwrite

oc --kubeconfig="${KUBECONFIG}" wait --for=create crd/storageclusters.ocs.openshift.io \
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
            resourceProfile: "lean",
            managedResources: {cephBlockPools: {defaultStorageClass: true}},
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
    }' | oc --kubeconfig="${KUBECONFIG}" apply -f -

WaitStorageClusterAndNoobaaReady
WaitStorageClassesReady
ConfigureDefaultStorage

oc --kubeconfig="${KUBECONFIG}" get storagecluster,storageclass \
    -n "${ODF_INSTALL_NAMESPACE}" \
    > "${ARTIFACT_DIR}/odf-hub-status.txt"
true
