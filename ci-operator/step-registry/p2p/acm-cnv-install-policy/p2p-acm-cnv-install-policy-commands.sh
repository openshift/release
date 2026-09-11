#!/bin/bash
#
# Deploy ACM Policy to install CNV on managed spokes and wait for HyperConverged Available.
#
# When CNV_ENABLE_CCLM=true, additionally waits for DecentralizedLiveMigration feature gate
# on KubeVirt and virt-synchronization-controller Available on each spoke (required for CCLM).
# When CNV_ENABLE_CCLM=false (upgrade/single-use), those checks are skipped.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset -i waitTimeoutMinutes="${CNV_WAIT_TIMEOUT_MINUTES}"
typeset -i pollIntervalSeconds="${CNV_POLL_INTERVAL_SECONDS}"
typeset -i waitTimeoutSeconds=$(( waitTimeoutMinutes * 60 ))
typeset policyNs="${CNV_POLICY_NAMESPACE}"

# Pre-compute conditional HCO featureGate line; empty string (no-op) when CCLM is disabled.
typeset cnvDecentralizedLiveMigrationLine=""
[[ "${CNV_ENABLE_CCLM}" == "true" ]] && \
    cnvDecentralizedLiveMigrationLine="                    decentralizedLiveMigration: true"

# Version-pinning state; set by the resolution block below once spoke kubeconfigs are loaded.
typeset startingCSV=""
typeset startingVersion=""
typeset startingCSVLine=""
typeset policyInstallPlanApproval="${CNV_POLICY_UPGRADE_APPROVAL}"

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
    typeset -i idx kcIdx
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

# GetCnvSubscriptionInstallPlan — return the pending InstallPlan name for hco-operatorhub, if any.
GetCnvSubscriptionInstallPlan() {
    typeset kubeconfig="${1:?}"
    typeset installPlan=""
    installPlan="$(oc --kubeconfig="${kubeconfig}" \
        get subscription.operators.coreos.com/hco-operatorhub \
        -n openshift-cnv \
        -o jsonpath='{.status.installplan.name}' || true)"
    [[ -n "${installPlan}" ]] && printf '%s' "${installPlan}"
}

# ApprovePinnedCnvInstallPlan — wait for the InstallPlan to appear then approve it.
# With installPlanApproval=Manual OLM will not proceed until the plan is approved.
ApprovePinnedCnvInstallPlan() {
    typeset kubeconfig="${1:?}"
    typeset clusterName="${2:?}"
    [[ -n "${startingCSV}" ]] || return 0
    typeset installPlan=""
    (
        SECONDS=0
        until [[ -n "${installPlan}" ]]; do
            installPlan="$(GetCnvSubscriptionInstallPlan "${kubeconfig}")" || true
            [[ -n "${installPlan}" ]] && break
            if (( SECONDS >= waitTimeoutSeconds )); then
                : "Timeout waiting for InstallPlan for pinned CNV ${startingCSV} on ${clusterName}"
                exit 1
            fi
            : "Waiting for InstallPlan (${clusterName}, ${SECONDS}/${waitTimeoutSeconds}s)"
            sleep "${pollIntervalSeconds}"
        done
        oc --kubeconfig="${kubeconfig}" \
            patch "installplan/${installPlan}" -n openshift-cnv \
            --type merge -p '{"spec":{"approved":true}}'
        : "Approved InstallPlan ${installPlan} for pinned CNV ${startingCSV} on ${clusterName}"
        true
    )
    true
}

# EnsurePinnedCnvSubscriptionOnSpoke — wait for openshift-cnv namespace and OperatorGroup to
# be created by ACM policy, then apply the subscription with startingCSV directly on the spoke.
# OLM only honors startingCSV on initial subscription creation; applying directly here bypasses
# the ACM ConfigurationPolicy to guarantee OLM sees startingCSV at create time.
# When startingCSV is empty this is a no-op (non-pinning scenarios).
EnsurePinnedCnvSubscriptionOnSpoke() {
    typeset kubeconfig="${1:?}"
    typeset clusterName="${2:?}"
    [[ -n "${startingCSV}" ]] || return 0

    : "Waiting for openshift-cnv namespace and OperatorGroup on ${clusterName}"
    (
        SECONDS=0
        until oc --kubeconfig="${kubeconfig}" \
                get namespace openshift-cnv 1>/dev/null \
            && oc --kubeconfig="${kubeconfig}" \
                get operatorgroup openshift-cnv -n openshift-cnv 1>/dev/null; do
            if (( SECONDS >= waitTimeoutSeconds )); then
                : "Timeout waiting for openshift-cnv namespace/OperatorGroup on ${clusterName}"
                exit 1
            fi
            : "Waiting for openshift-cnv prerequisites (${clusterName}, ${SECONDS}/${waitTimeoutSeconds}s)"
            sleep "${pollIntervalSeconds}"
        done
        true
    )

    : "Applying pinned CNV subscription startingCSV=${startingCSV} directly on ${clusterName}"
    oc --kubeconfig="${kubeconfig}" \
        create -f - --dry-run=client -o yaml --save-config <<EOF | oc --kubeconfig="${kubeconfig}" apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  channel: ${CNV_POLICY_CHANNEL}
  installPlanApproval: Manual
  name: kubevirt-hyperconverged
  source: ${CNV_POLICY_SOURCE}
  sourceNamespace: ${CNV_POLICY_SOURCE_NAMESPACE}
  startingCSV: ${startingCSV}
EOF
    ApprovePinnedCnvInstallPlan "${kubeconfig}" "${clusterName}"
    true
}

# WaitForCNV — poll spoke until HyperConverged CR exists and Available=True (runs in subshell).
# When CNV_ENABLE_CCLM=true, additionally waits for DecentralizedLiveMigration feature gate
# and virt-synchronization-controller Available (required for CCLM cross-cluster sync).
WaitForCNV() {
    typeset clusterName="${1:?}"
    typeset kubeconfig="${2:?}"
    typeset resultFile="${3:?}"

    (
        # TODO: verify oc wait --for=create is available on target OCP version (OCP 4.20+)
        # If so, replace this loop with: oc wait hyperconverged/kubevirt-hyperconverged --for=create
        SECONDS=0
        while (( SECONDS < waitTimeoutSeconds )); do
            if oc --kubeconfig="${kubeconfig}" -n openshift-cnv get hyperconverged kubevirt-hyperconverged 1>/dev/null; then
                break
            fi
            : "Waiting for HyperConverged CR (${clusterName}, ${SECONDS}/${waitTimeoutSeconds}s)"
            sleep "${pollIntervalSeconds}"
        done
        (( SECONDS < waitTimeoutSeconds ))

        : "Waiting for HyperConverged Available (${clusterName}, timeout=${waitTimeoutSeconds}s)"
        oc --kubeconfig="${kubeconfig}" -n openshift-cnv wait hyperconverged/kubevirt-hyperconverged \
            --for=condition=Available --timeout="${waitTimeoutSeconds}s" 1>/dev/null

        # When pinned: assert installPlanApproval=Manual to block OLM auto-upgrade, then verify
        # the installed CSV matches the requested version before proceeding.
        if [[ -n "${startingCSV}" ]]; then
            : "Pinning: asserting installPlanApproval=Manual to block auto-upgrade on ${clusterName}"
            oc --kubeconfig="${kubeconfig}" \
                patch subscription.operators.coreos.com/hco-operatorhub \
                -n openshift-cnv --type merge \
                -p '{"spec":{"installPlanApproval":"Manual"}}'
            typeset installedCsv="" installedVersion=""
            installedCsv="$(oc --kubeconfig="${kubeconfig}" \
                get subscription.operators.coreos.com/hco-operatorhub -n openshift-cnv \
                -o jsonpath='{.status.installedCSV}' || true)"
            [[ -n "${installedCsv}" ]] && installedVersion="$(oc --kubeconfig="${kubeconfig}" \
                get csv "${installedCsv}" -n openshift-cnv \
                -o jsonpath='{.spec.version}' || true)"
            [[ "${installedCsv}" == "${startingCSV}" && "${installedVersion}" == "${startingVersion}" ]] || {
                : "CNV installedCSV=${installedCsv} (${installedVersion}) does not match pinned ${startingCSV} (${startingVersion}) on ${clusterName}"
                exit 1
            }
            : "CNV pinned at ${installedCsv} (${installedVersion}) on ${clusterName}"
        fi

        if [[ "${CNV_ENABLE_CCLM}" == "true" ]]; then
            SECONDS=0
            while (( SECONDS < waitTimeoutSeconds )); do
                if oc --kubeconfig="${kubeconfig}" -n openshift-cnv get kubevirt kubevirt-kubevirt-hyperconverged \
                        -o json \
                        | jq -e '.spec.configuration.developerConfiguration.featureGates // [] | contains(["DecentralizedLiveMigration"])' \
                        > /dev/null; then
                    break
                fi
                : "Waiting for DecentralizedLiveMigration gate (${clusterName}, ${SECONDS}/${waitTimeoutSeconds}s)"
                sleep "${pollIntervalSeconds}"
            done
            oc --kubeconfig="${kubeconfig}" -n openshift-cnv get kubevirt kubevirt-kubevirt-hyperconverged \
                -o json \
                | jq -e '.spec.configuration.developerConfiguration.featureGates // [] | contains(["DecentralizedLiveMigration"])' \
                > /dev/null

            SECONDS=0
            while (( SECONDS < waitTimeoutSeconds )); do
                if oc --kubeconfig="${kubeconfig}" -n openshift-cnv get deployment virt-synchronization-controller \
                        1>/dev/null; then
                    break
                fi
                : "Waiting for virt-synchronization-controller deployment (${clusterName}, ${SECONDS}/${waitTimeoutSeconds}s)"
                sleep "${pollIntervalSeconds}"
            done
            oc --kubeconfig="${kubeconfig}" -n openshift-cnv wait deployment/virt-synchronization-controller \
                --for=condition=Available --timeout="${waitTimeoutSeconds}s" 1>/dev/null
        fi

        printf '0' > "${resultFile}"
        true
    ) || {
        printf '1' > "${resultFile}"
        false
    }
}

typeset -a clusterNamesArr=()
mapfile -t clusterNamesArr < <(LoadSpokeClusterNames)

# Resolve latest kubevirt-hyperconverged version for major.minor from the spoke catalog.
ResolveCnvLatestVersion() {
    typeset majorMinor="$1"
    typeset channel="$2"
    typeset spokeKubeconfig="${3:-}"
    typeset versionPrefix="${majorMinor}."

    [[ -n "${spokeKubeconfig}" ]] || spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"

    oc --kubeconfig="${spokeKubeconfig}" get packagemanifest kubevirt-hyperconverged \
        -n openshift-marketplace -o json \
        | jq -r --arg ch "${channel}" --arg prefix "${versionPrefix}" '
            .status.channels[]
            | select(.name == $ch)
            | .entries[]
            | select(.version | startswith($prefix))
            | .version' \
        | sort -V | tail -n1
}

# Resolve packagemanifest CSV name for an exact x.y.z version on the spoke catalog channel.
ResolveCnvCsvForVersion() {
    typeset version="$1"
    typeset channel="$2"
    typeset spokeKubeconfig="${3:-}"

    [[ -n "${spokeKubeconfig}" ]] || spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"

    oc --kubeconfig="${spokeKubeconfig}" get packagemanifest kubevirt-hyperconverged \
        -n openshift-marketplace -o json \
        | jq -r --arg ch "${channel}" --arg ver "${version}" '
            .status.channels[]
            | select(.name == $ch)
            | .entries[]
            | select(.version == $ver)
            | .name' \
        | head -n1
}

# Installed CNV CSV on the spoke: hco-operatorhub subscription, else package match, else Succeeded CSV.
GetInstalledCnvCsv() {
    typeset csv
    if oc get subscription.operators.coreos.com hco-operatorhub -n openshift-cnv 1>/dev/null; then
        csv="$(oc get subscription.operators.coreos.com hco-operatorhub -n openshift-cnv \
            -o jsonpath='{.status.installedCSV}' || true)"
        if [[ -n "${csv}" ]]; then
            printf '%s' "${csv}"
            return 0
        fi
    fi
    csv="$(oc get subscription.operators.coreos.com -n openshift-cnv -o json \
        | jq -r '.items[] | select(.spec.name=="kubevirt-hyperconverged") | .status.installedCSV' \
        | grep -v '^$' | head -n1 || true)"
    if [[ -n "${csv}" ]]; then
        printf '%s' "${csv}"
        return 0
    fi
    oc get csv -n openshift-cnv -o json \
        | jq -r '
            .items[]
            | select(.metadata.labels["operators.coreos.com/kubevirt-hyperconverged.openshift-cnv"] != null)
            | select(.status.phase == "Succeeded")
            | .metadata.name' \
        | head -n1
}

#=====================
# ODF virt StorageClass — annotate after all spokes have HyperConverged Available.
# ODF creates ocs-storagecluster-ceph-rbd-virtualization when it detects the
# virtualmachines.kubevirt.io CRD. Called after WaitForCNV completes so the virt SC
# is guaranteed to exist. Skipped when ODF_DEFAULT_STORAGE_CLASS is empty or not the virt SC
# (e.g. CCLM job which installs ODF after this step).
#=====================
# Called per-spoke (with spoke KUBECONFIG) after all spokes have HyperConverged Available.
ConfigureOdfVirtStorageClassDefaults() {
    typeset kubeconfig="${1:?}"
    typeset -r virtSc="${ODF_DEFAULT_STORAGE_CLASS}"
    [[ -n "${virtSc}" && "${virtSc}" == *-ceph-rbd-virtualization ]] || return 0

    oc --kubeconfig="${kubeconfig}" wait crd/virtualmachines.kubevirt.io --for=create \
        --timeout="${ODF_VIRT_STORAGE_CLASS_WAIT_TIMEOUT}"

    if ! oc --kubeconfig="${kubeconfig}" wait "storageclass/${virtSc}" --for=create \
            --timeout="${ODF_VIRT_STORAGE_CLASS_WAIT_TIMEOUT}"; then
        oc --kubeconfig="${kubeconfig}" get sc || true
        oc --kubeconfig="${kubeconfig}" get crd/virtualmachines.kubevirt.io -o yaml \
            > "${ARTIFACT_DIR}/kubevirt-crd.yaml" 2>&1 || true
        oc --kubeconfig="${kubeconfig}" get storageconsumer -n openshift-storage -o yaml \
            > "${ARTIFACT_DIR}/storageconsumer.yaml" 2>&1 || true
        exit 1
    fi

    oc --kubeconfig="${kubeconfig}" get sc -o name | xargs -rI{} oc --kubeconfig="${kubeconfig}" annotate {} \
        storageclass.kubernetes.io/is-default-class- \
        storageclass.kubevirt.io/is-default-virt-class- --overwrite
    oc --kubeconfig="${kubeconfig}" annotate storageclass "${virtSc}" \
        storageclass.kubernetes.io/is-default-class=true \
        storageclass.kubevirt.io/is-default-virt-class=true --overwrite

    typeset -r snapClass='ocs-storagecluster-rbdplugin-snapclass'
    if oc --kubeconfig="${kubeconfig}" get volumesnapshotclass "${snapClass}" 1>/dev/null; then
        oc --kubeconfig="${kubeconfig}" get volumesnapshotclass -o name \
            | xargs -rI{} oc --kubeconfig="${kubeconfig}" annotate {} snapshot.storage.kubernetes.io/is-default-class- --overwrite
        oc --kubeconfig="${kubeconfig}" annotate volumesnapshotclass "${snapClass}" \
            snapshot.storage.kubernetes.io/is-default-class=true --overwrite
        typeset -r snapCtrlNs='openshift-cluster-storage-operator'
        typeset -r snapDeploy='csi-snapshot-controller'
        if oc --kubeconfig="${kubeconfig}" -n "${snapCtrlNs}" get deployment "${snapDeploy}" 1>/dev/null; then
            oc --kubeconfig="${kubeconfig}" -n "${snapCtrlNs}" rollout restart "deployment/${snapDeploy}"
            oc --kubeconfig="${kubeconfig}" -n "${snapCtrlNs}" rollout status "deployment/${snapDeploy}" --timeout=5m
        fi
    fi
    true
}

typeset -a spokeKubeconfigsArr=()
mapfile -t spokeKubeconfigsArr < <(LoadSpokeKubeconfigs "${clusterNamesArr[@]}")

oc create namespace "${policyNs}" --dry-run=client -o yaml | oc apply -f -

typeset clusterName=""
for clusterName in "${clusterNamesArr[@]}"; do
    oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: ${clusterName}-set
  namespace: ${policyNs}
spec:
  clusterSet: ${clusterName}-set
EOF
done

typeset clusterSetsYaml=""
for clusterName in "${clusterNamesArr[@]}"; do
    clusterSetsYaml+="    - ${clusterName}-set"$'\n'
done

# Resolve startingCSV when version pinning is requested via CNV_POLICY_INSTALL_MAJOR_MINOR.
# Two-step approach matching PR #75954: (1) resolve latest patch version for the target
# major.minor using .version field + sort -V (true semver); (2) resolve CSV name for that
# exact version. Queries the first spoke's PackageManifest (not the hub's) so the resolved
# CSV is guaranteed to be available on the spokes.
if [[ -n "${CNV_POLICY_INSTALL_MAJOR_MINOR}" ]]; then
    typeset firstSpokeKubeconfig="${spokeKubeconfigsArr[0]}"
    : "Resolving startingCSV for kubevirt-hyperconverged v${CNV_POLICY_INSTALL_MAJOR_MINOR} channel=${CNV_POLICY_CHANNEL} (from spoke)"

    # Step 1: latest patch version for the requested major.minor (semver-sorted)
    startingVersion="$(
        oc --kubeconfig="${firstSpokeKubeconfig}" \
            get packagemanifest kubevirt-hyperconverged -n openshift-marketplace -o json |
        jq -r \
            --arg ch "${CNV_POLICY_CHANNEL}" \
            --arg prefix "${CNV_POLICY_INSTALL_MAJOR_MINOR}." \
            '.status.channels[] | select(.name == $ch) |
             .entries[] | select(.version | startswith($prefix)) | .version' |
        sort -V | tail -n1
    )"
    [[ -n "${startingVersion}" ]] || {
        : "No version found for kubevirt-hyperconverged v${CNV_POLICY_INSTALL_MAJOR_MINOR} in channel ${CNV_POLICY_CHANNEL}"
        false
    }

    # Step 2: CSV name for the exact resolved version
    startingCSV="$(
        oc --kubeconfig="${firstSpokeKubeconfig}" \
            get packagemanifest kubevirt-hyperconverged -n openshift-marketplace -o json |
        jq -r \
            --arg ch "${CNV_POLICY_CHANNEL}" \
            --arg ver "${startingVersion}" \
            '.status.channels[] | select(.name == $ch) |
             .entries[] | select(.version == $ver) | .name' |
        head -n1
    )"
    [[ -n "${startingCSV}" ]] || {
        : "No CSV name found for kubevirt-hyperconverged version ${startingVersion} in channel ${CNV_POLICY_CHANNEL}"
        false
    }

    policyInstallPlanApproval="Manual"
    startingCSVLine="                  startingCSV: ${startingCSV}"
    printf '%s\n' "${startingCSV}" > "${ARTIFACT_DIR}/cnv-policy-starting-csv"
    printf '%s\n' "${startingVersion}" > "${ARTIFACT_DIR}/cnv-policy-starting-version"
    : "Resolved: channel=${CNV_POLICY_CHANNEL} version=${startingVersion} csv=${startingCSV}"
fi

oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: install-cnv-operator
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
          name: cnv-olm-subscription
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
                  channel: ${CNV_POLICY_CHANNEL}
                  installPlanApproval: ${policyInstallPlanApproval}
                  name: kubevirt-hyperconverged
                  source: ${CNV_POLICY_SOURCE}
                  sourceNamespace: ${CNV_POLICY_SOURCE_NAMESPACE}
${startingCSVLine}
          severity: critical
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: openshift-virtualization-deployment
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
                  virtualMachineOptions:
                    disableFreePageReporting: false
                    disableSerialConsoleLog: true
                  higherWorkloadDensity:
                    memoryOvercommitPercentage: 100
                  liveMigrationConfig:
                    allowAutoConverge: false
                    allowPostCopy: false
                    completionTimeoutPerGiB: 800
                    parallelMigrationsPerCluster: 5
                    parallelOutboundMigrationsPerNode: 2
                    progressTimeout: 150
                  certConfig:
                    ca:
                      duration: 48h0m0s
                      renewBefore: 24h0m0s
                    server:
                      duration: 24h0m0s
                      renewBefore: 12h0m0s
                  applicationAwareConfig:
                    allowApplicationAwareClusterResourceQuota: false
                    vmiCalcConfigName: DedicatedVirtualResources
                  featureGates:
                    deployTektonTaskResources: false
                    enableCommonBootImageImport: true
                    withHostPassthroughCPU: false
                    downwardMetrics: false
                    disableMDevConfiguration: false
${cnvDecentralizedLiveMigrationLine}
                    enableApplicationAwareQuota: false
                    deployKubeSecondaryDNS: false
                    nonRoot: true
                    alignCPUs: false
                    enableManagedTenantQuota: false
                    primaryUserDefinedNetworkBinding: false
                    deployVmConsoleProxy: false
                    persistentReservation: false
                    autoResourceLimits: false
                    deployKubevirtIpamController: false
                  workloadUpdateStrategy:
                    batchEvictionInterval: 1m0s
                    batchEvictionSize: 10
                    workloadUpdateMethods:
                      - LiveMigrate
                  uninstallStrategy: BlockUninstallIfWorkloadsExist
                  resourceRequirements:
                    vmiCPUAllocationRatio: 10
            - complianceType: musthave
              objectDefinition:
                apiVersion: hostpathprovisioner.kubevirt.io/v1beta1
                kind: HostPathProvisioner
                metadata:
                  name: hostpath-provisioner
                spec:
                  imagePullPolicy: IfNotPresent
                  storagePools:
                    - name: local
                      path: /var/hpvolumes
                      pvcTemplate:
                        accessModes:
                          - ReadWriteOnce
                        resources:
                          requests:
                            storage: 50Gi
                  workload:
                    nodeSelector:
                      kubernetes.io/os: linux
          severity: critical
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: kubevirt-hyperconverged-available
        spec:
          remediationAction: inform
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: hco.kubevirt.io/v1beta1
                kind: HyperConverged
                metadata:
                  name: kubevirt-hyperconverged
                  namespace: openshift-cnv
                status:
                  conditions:
                    - message: Reconcile completed successfully
                      reason: ReconcileCompleted
                      status: "True"
                    - type: Available
          severity: critical
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: install-cnv-placement
  namespace: ${policyNs}
spec:
  tolerations:
    - key: cluster.open-cluster-management.io/unreachable
      operator: Exists
    - key: cluster.open-cluster-management.io/unavailable
      operator: Exists
  clusterSets:
${clusterSetsYaml}---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: install-cnv-placement
  namespace: ${policyNs}
placementRef:
  name: install-cnv-placement
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
subjects:
  - name: install-cnv-operator
    apiGroup: policy.open-cluster-management.io
    kind: Policy
EOF

# Per-spoke: apply the subscription directly with startingCSV before OLM can pick it up
# without it. This is sequential so each spoke's InstallPlan is approved before the next.
typeset -i ensureIdx
for (( ensureIdx = 0; ensureIdx < ${#clusterNamesArr[@]}; ensureIdx++ )); do
    EnsurePinnedCnvSubscriptionOnSpoke \
        "${spokeKubeconfigsArr[ensureIdx]}" \
        "${clusterNamesArr[ensureIdx]}"
done

typeset resultsDir=""
typeset -a pidsArr=()
typeset -i failedCount=0 idx waitRc=0
typeset resultFile="" storedRc=""

resultsDir="$(mktemp -d "${ARTIFACT_DIR}/cnv-policy-wait.XXXXXX")"
trap 'rm -rf "${resultsDir}"' EXIT

for ((idx = 0; idx < ${#clusterNamesArr[@]}; idx++)); do
    resultFile="${resultsDir}/cluster-$((idx + 1)).result"
    WaitForCNV "${clusterNamesArr[idx]}" "${spokeKubeconfigsArr[idx]}" "${resultFile}" &
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

(( failedCount == 0 ))

# Per-spoke: configure virt StorageClass and snapshot defaults after all spokes have CNV Available.
# ODF creates ocs-storagecluster-ceph-rbd-virtualization when it detects the
# virtualmachines.kubevirt.io CRD registered by CNV. HyperConverged Available on all spokes
# guarantees the CRD and virt SC both exist. Sequential so annotations settle before downstream
# steps (openshift-virtualization-upgrade-prep) begin boot-image operations.
for ((idx = 0; idx < ${#clusterNamesArr[@]}; idx++)); do
    ConfigureOdfVirtStorageClassDefaults "${spokeKubeconfigsArr[idx]}"
done

# When pinned: remove startingCSV from all spoke subscriptions and from the ACM policy so
# downstream CNV upgrade steps can create a new InstallPlan. installPlanApproval stays Manual
# to prevent OLM from auto-upgrading until the upgrade step explicitly approves the next plan.
if [[ -n "${startingCSV}" ]]; then
    : "Releasing startingCSV pin for downstream CNV upgrade steps"
    typeset -i releaseIdx
    for (( releaseIdx = 0; releaseIdx < ${#spokeKubeconfigsArr[@]}; releaseIdx++ )); do
        typeset specStartingCsv=""
        specStartingCsv="$(oc --kubeconfig="${spokeKubeconfigsArr[releaseIdx]}" \
            get subscription.operators.coreos.com/hco-operatorhub -n openshift-cnv \
            -o jsonpath='{.spec.startingCSV}' || true)"
        if [[ -n "${specStartingCsv}" ]]; then
            oc --kubeconfig="${spokeKubeconfigsArr[releaseIdx]}" \
                patch subscription.operators.coreos.com/hco-operatorhub -n openshift-cnv \
                --type=json -p '[{"op":"remove","path":"/spec/startingCSV"}]'
            : "Removed startingCSV from ${clusterNamesArr[releaseIdx]} subscription"
        fi
    done
    oc patch policy install-cnv-operator -n "${policyNs}" --type=json \
        -p '[{"op":"remove","path":"/spec/policy-templates/0/objectDefinition/spec/object-templates/2/objectDefinition/spec/startingCSV"}]'
    : "Updated ACM policy to stop enforcing startingCSV on hco-operatorhub"
fi

: "CNV installation via policy completed successfully"
true
