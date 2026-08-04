#!/bin/bash
#
# Install CNV (OpenShift Virtualization / KubeVirt) on the ACM hub cluster via ACM Policy
# targeting local-cluster.
#
# The hub cluster is represented in ACM as the ManagedCluster "local-cluster", which resides
# in the "default" ManagedClusterSet. By binding that set to the policy namespace and using a
# Placement with a name predicate matching "local-cluster", ACM pushes the CNV Policy exclusively
# to the hub — the same declarative path used for spokes in p2p-acm-cnv-install-policy.
#
# Why a separate step from p2p-acm-cnv-install-policy:
#   - That step builds its Placement from SHARED_DIR spoke cluster names and ClusterSet bindings
#     specific to each spoke. It does not include local-cluster.
#   - The hub requires decentralizedLiveMigration=true and the step must also wait for the
#     virt-synchronization-controller (CCLM requirement), which is the same as spoke CCLM waits
#     but driven by KUBECONFIG (hub kubeconfig) rather than a spoke kubeconfig.
#
# Run after p2p-install-odf-hub (ODF must be Available so it can detect the
# virtualmachines.kubevirt.io CRD registered by CNV and create the virt StorageClass).
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

typeset -i waitTimeoutSeconds=$(( CNV_HUB_WAIT_TIMEOUT_MINUTES * 60 ))
typeset -i pollIntervalSeconds="${CNV_HUB_POLL_INTERVAL_SECONDS}"
typeset policyNs="${CNV_HUB_POLICY_NAMESPACE}"

# DumpDiagnostics — write CNV and ACM policy resources to ARTIFACT_DIR on failure.
DumpDiagnostics() {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    typeset diagDir="${ARTIFACT_DIR}/cnv-hub"
    mkdir -p "${diagDir}"
    oc get subscription.operators.coreos.com,csv,hyperconverged,kubevirt \
        -n openshift-cnv -o wide > "${diagDir}/cnv-resources.txt" 2>&1 || true
    oc get policy,placement,placementbinding \
        -n "${policyNs}" > "${diagDir}/policy-resources.txt" 2>&1 || true
    oc get events -n openshift-cnv --sort-by='.lastTimestamp' \
        > "${diagDir}/cnv-events.txt" 2>&1 || true
    oc get pods -n openshift-cnv -o wide \
        > "${diagDir}/cnv-pods.txt" 2>&1 || true
    oc get sc > "${diagDir}/storage-classes.txt" 2>&1 || true
}

# ResolveStartingCsv — resolve the kubevirt-hyperconverged CSV from the hub PackageManifest.
# When CNV_HUB_INSTALL_MAJOR_MINOR is set, returns the latest patch CSV for that major.minor.
# When unset, returns the channel's currentCSV.
# Prints empty string on lookup failure (non-pinning case continues with no startingCSV).
ResolveStartingCsv() {
    typeset manifestJson
    manifestJson="$(oc get packagemanifest kubevirt-hyperconverged \
        -n openshift-marketplace -o json)"

    if [[ -n "${CNV_HUB_INSTALL_MAJOR_MINOR}" ]]; then
        typeset latestVersion csvName
        latestVersion="$(jq -r \
            --arg ch "${CNV_HUB_CHANNEL}" \
            --arg prefix "${CNV_HUB_INSTALL_MAJOR_MINOR}." \
            '.status.channels[] | select(.name == $ch) |
             .entries[] | select(.version | startswith($prefix)) | .version' \
            <<< "${manifestJson}" | sort -V | tail -n1)"
        [[ -n "${latestVersion}" ]] || {
            : "No version for CNV ${CNV_HUB_INSTALL_MAJOR_MINOR} in channel ${CNV_HUB_CHANNEL} — falling back to channel head"
            return 0
        }
        csvName="$(jq -r \
            --arg ch "${CNV_HUB_CHANNEL}" \
            --arg ver "${latestVersion}" \
            '.status.channels[] | select(.name == $ch) |
             .entries[] | select(.version == $ver) | .name' \
            <<< "${manifestJson}" | head -n1)"
        [[ -n "${csvName}" ]] || {
            : "No CSV name for CNV version ${latestVersion} in channel ${CNV_HUB_CHANNEL}"
            return 0
        }
        printf '%s' "${csvName}"
    else
        jq -r \
            --arg ch "${CNV_HUB_CHANNEL}" \
            '.status.channels[] | select(.name == $ch) | .currentCSV' \
            <<< "${manifestJson}" | head -n1
    fi
}

# WaitForCNV — wait for HyperConverged Available, DecentralizedLiveMigration gate, and
# virt-synchronization-controller Available on the hub cluster using KUBECONFIG.
WaitForCNV() {
    # Wait for HyperConverged CR to appear.
    SECONDS=0
    while (( SECONDS < waitTimeoutSeconds )); do
        if oc -n openshift-cnv get hyperconverged kubevirt-hyperconverged 1>/dev/null; then
            break
        fi
        : "Waiting for HyperConverged CR on hub (${SECONDS}/${waitTimeoutSeconds}s)"
        sleep "${pollIntervalSeconds}"
    done
    (( SECONDS < waitTimeoutSeconds ))

    : "Waiting for HyperConverged Available on hub (timeout=${waitTimeoutSeconds}s)"
    oc -n openshift-cnv wait hyperconverged/kubevirt-hyperconverged \
        --for=condition=Available --timeout="${waitTimeoutSeconds}s" 1>/dev/null

    # DecentralizedLiveMigration featureGate — required for CCLM on hub.
    SECONDS=0
    while (( SECONDS < waitTimeoutSeconds )); do
        if oc -n openshift-cnv get kubevirt kubevirt-kubevirt-hyperconverged \
                -o json \
                | jq -e '.spec.configuration.developerConfiguration.featureGates // [] | contains(["DecentralizedLiveMigration"])' \
                > /dev/null; then
            : "DecentralizedLiveMigration featureGate active on hub"
            break
        fi
        : "Waiting for DecentralizedLiveMigration gate on hub (${SECONDS}/${waitTimeoutSeconds}s)"
        sleep "${pollIntervalSeconds}"
    done
    oc -n openshift-cnv get kubevirt kubevirt-kubevirt-hyperconverged \
        -o json \
        | jq -e '.spec.configuration.developerConfiguration.featureGates // [] | contains(["DecentralizedLiveMigration"])' \
        > /dev/null

    # virt-synchronization-controller — required for CCLM cross-cluster sync.
    SECONDS=0
    while (( SECONDS < waitTimeoutSeconds )); do
        if oc -n openshift-cnv get deployment virt-synchronization-controller \
                1>/dev/null; then
            break
        fi
        : "Waiting for virt-synchronization-controller deployment on hub (${SECONDS}/${waitTimeoutSeconds}s)"
        sleep "${pollIntervalSeconds}"
    done
    oc -n openshift-cnv wait deployment/virt-synchronization-controller \
        --for=condition=Available --timeout="${waitTimeoutSeconds}s" 1>/dev/null
    : "virt-synchronization-controller Available on hub"
}

# WaitVirtStorageClassAndAnnotate — ODF creates the virt SC after KubeVirt CRDs are registered.
# Annotate it as the KubeVirt default virt class on the hub.
WaitVirtStorageClassAndAnnotate() {
    [[ -n "${CNV_HUB_VIRT_STORAGE_CLASS}" ]] || return 0

    typeset -i scWaitMax=$(( CNV_HUB_VIRT_SC_WAIT_TIMEOUT_MINUTES * 60 ))
    SECONDS=0
    while (( SECONDS < scWaitMax )); do
        if oc get "storageclass/${CNV_HUB_VIRT_STORAGE_CLASS}" 1>/dev/null; then
            break
        fi
        : "Waiting for virt StorageClass ${CNV_HUB_VIRT_STORAGE_CLASS} on hub (${SECONDS}/${scWaitMax}s)"
        sleep 15
    done

    if ! oc get "storageclass/${CNV_HUB_VIRT_STORAGE_CLASS}" 1>/dev/null; then
        : "WARNING: virt StorageClass ${CNV_HUB_VIRT_STORAGE_CLASS} not found after ${scWaitMax}s — skipping annotation"
        return 0
    fi

    oc annotate "storageclass/${CNV_HUB_VIRT_STORAGE_CLASS}" \
        storageclass.kubevirt.io/is-default-virt-class=true --overwrite
    : "Annotated ${CNV_HUB_VIRT_STORAGE_CLASS} as kubevirt default virt StorageClass on hub"
}

# --- Main ---

trap DumpDiagnostics ERR

# Resolve startingCSV for optional version pinning.
typeset startingCsv=""
startingCsv="$(ResolveStartingCsv)"
typeset startingCsvLine=""
[[ -z "${startingCsv}" ]] || startingCsvLine="                  startingCSV: ${startingCsv}"
: "CNV hub startingCSV resolved: '${startingCsv}' (channel=${CNV_HUB_CHANNEL})"

# Policy namespace for ACM resources (Policy, Placement, PlacementBinding, ClusterSetBinding).
oc create namespace "${policyNs}" --dry-run=client -o yaml | oc apply -f -

# Bind the "default" ManagedClusterSet to the policy namespace.
# local-cluster lives in the "default" ManagedClusterSet by default in ACM.
oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: default
  namespace: ${policyNs}
spec:
  clusterSet: default
EOF

# Apply Policy, Placement, and PlacementBinding.
# The Placement targets only local-cluster by name predicate within the default ClusterSet.
oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: install-cnv-hub
  namespace: ${policyNs}
  annotations:
    policy.open-cluster-management.io/categories: ""
    policy.open-cluster-management.io/standards: ""
    policy.open-cluster-management.io/controls: ""
spec:
  disabled: false
  remediationAction: enforce
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: cnv-hub-olm-subscription
        spec:
          remediationAction: enforce
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: v1
                kind: Namespace
                metadata:
                  name: openshift-cnv
            - complianceType: musthave
              objectDefinition:
                apiVersion: operators.coreos.com/v1
                kind: OperatorGroup
                metadata:
                  name: openshift-cnv
                  namespace: openshift-cnv
                spec:
                  targetNamespaces:
                    - openshift-cnv
            - complianceType: musthave
              objectDefinition:
                apiVersion: operators.coreos.com/v1alpha1
                kind: Subscription
                metadata:
                  name: hco-operatorhub
                  namespace: openshift-cnv
                spec:
                  channel: ${CNV_HUB_CHANNEL}
                  installPlanApproval: Automatic
                  name: kubevirt-hyperconverged
                  source: ${CNV_HUB_SOURCE}
                  sourceNamespace: ${CNV_HUB_SOURCE_NAMESPACE}
${startingCsvLine}
          severity: critical
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: cnv-hub-hyperconverged
        spec:
          remediationAction: enforce
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: hco.kubevirt.io/v1beta1
                kind: HyperConverged
                metadata:
                  name: kubevirt-hyperconverged
                  namespace: openshift-cnv
                  annotations:
                    deployOVS: "false"
                spec:
                  featureGates:
                    decentralizedLiveMigration: true
                    enableCommonBootImageImport: true
                    deployTektonTaskResources: false
                    withHostPassthroughCPU: false
                    downwardMetrics: false
                    disableMDevConfiguration: false
                    enableApplicationAwareQuota: false
                    deployKubeSecondaryDNS: false
                    nonRoot: true
                    persistentReservation: false
                  liveMigrationConfig:
                    allowAutoConverge: false
                    allowPostCopy: false
                    completionTimeoutPerGiB: 800
                    parallelMigrationsPerCluster: 5
                    parallelOutboundMigrationsPerNode: 2
                    progressTimeout: 150
                  workloadUpdateStrategy:
                    batchEvictionInterval: 1m0s
                    batchEvictionSize: 10
                    workloadUpdateMethods:
                      - LiveMigrate
                  uninstallStrategy: BlockUninstallIfWorkloadsExist
          severity: critical
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: install-cnv-hub-placement
  namespace: ${policyNs}
spec:
  tolerations:
    - key: cluster.open-cluster-management.io/unreachable
      operator: Exists
    - key: cluster.open-cluster-management.io/unavailable
      operator: Exists
  clusterSets:
    - default
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchExpressions:
            - key: name
              operator: In
              values:
                - local-cluster
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: install-cnv-hub-placement
  namespace: ${policyNs}
placementRef:
  name: install-cnv-hub-placement
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
subjects:
  - name: install-cnv-hub
    apiGroup: policy.open-cluster-management.io
    kind: Policy
EOF

WaitForCNV
WaitVirtStorageClassAndAnnotate

if [[ -n "${ARTIFACT_DIR}" ]]; then
    mkdir -p "${ARTIFACT_DIR}/cnv-hub"
    oc get hyperconverged/kubevirt-hyperconverged -n openshift-cnv -o yaml \
        > "${ARTIFACT_DIR}/cnv-hub/hyperconverged.yaml" || true
    oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
        -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' \
        > "${ARTIFACT_DIR}/cnv-hub/kubevirt-feature-gates.txt" || true
    oc get deployment/virt-synchronization-controller -n openshift-cnv \
        > "${ARTIFACT_DIR}/cnv-hub/sync-controller.txt" || true
    oc get sc > "${ARTIFACT_DIR}/cnv-hub/storage-classes.txt" || true
fi

: "CNV installation on hub via ACM policy completed: HyperConverged Available, DecentralizedLiveMigration active, sync controller running"
true
