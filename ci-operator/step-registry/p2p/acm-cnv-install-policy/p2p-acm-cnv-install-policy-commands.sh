#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Helper functions
#=====================
Need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[FATAL] '$1' not found" >&2
        exit 1
    }
}

Need oc
Need jq

#=====================
# Load spoke cluster names
#=====================
# Support both multi-cluster (managed-cluster-names) and single-cluster (managed-cluster-name) setups
typeset -a cluster_names=()
if [[ -f "${SHARED_DIR}/managed-cluster-names" ]]; then
    mapfile -t cluster_names < "${SHARED_DIR}/managed-cluster-names"
    echo "[INFO] Found ${#cluster_names[@]} spoke cluster(s) from managed-cluster-names"
elif [[ -f "${SHARED_DIR}/managed-cluster-name" ]]; then
    cluster_names+=("$(cat "${SHARED_DIR}/managed-cluster-name")")
    echo "[INFO] Found 1 spoke cluster from managed-cluster-name (legacy mode)"
else
    echo "[ERROR] No spoke cluster name files found" >&2
    exit 1
fi

if [[ ${#cluster_names[@]} -eq 0 ]]; then
    echo "[ERROR] No cluster names found in files" >&2
    exit 1
fi

# Validate and load kubeconfig files for all spoke clusters
typeset -a spoke_kubeconfigs=()
typeset idx=0
typeset kc_file=""
for ((i = 0; i < ${#cluster_names[@]}; i++)); do
    idx=$((i + 1))
    kc_file="${SHARED_DIR}/managed-cluster-kubeconfig-${idx}"

    # Fall back to legacy kubeconfig for single-cluster setup
    if [[ ! -f "${kc_file}" && ${#cluster_names[@]} -eq 1 ]]; then
        kc_file="${SHARED_DIR}/managed-cluster-kubeconfig"
    fi

    if [[ ! -f "${kc_file}" ]]; then
        echo "[ERROR] Spoke kubeconfig not found: ${kc_file}" >&2
        exit 1
    fi

    spoke_kubeconfigs+=("${kc_file}")
    echo "[INFO] Spoke ${idx}: ${cluster_names[i]} (kubeconfig: ${kc_file})"
done

#=====================
# Configuration variables
#=====================
typeset policy_ns="install-cnv"
typeset wait_timeout_minutes="${CNV_WAIT_TIMEOUT_MINUTES:-30}"
typeset poll_interval_seconds="${CNV_POLL_INTERVAL_SECONDS:-30}"

#=====================
# Create policy namespace
#=====================
echo "[INFO] Creating policy namespace '${policy_ns}'"
oc create namespace "${policy_ns}" --dry-run=client -o yaml | oc apply -f -

#=====================
# Create ManagedClusterSetBinding for each cluster
#=====================
echo "[INFO] Creating ManagedClusterSetBindings for ${#cluster_names[@]} cluster set(s)"
typeset cluster_name=""
for cluster_name in "${cluster_names[@]}"; do
    echo "[INFO] Creating ManagedClusterSetBinding for cluster set '${cluster_name}-set'"
    oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: ${cluster_name}-set
  namespace: ${policy_ns}
spec:
  clusterSet: ${cluster_name}-set
EOF
done

#=====================
# Build cluster sets list for Placement
#=====================
# Generate YAML list of cluster sets for the Placement spec
typeset cluster_sets_yaml=""
for cluster_name in "${cluster_names[@]}"; do
    cluster_sets_yaml+="    - ${cluster_name}-set"$'\n'
done

#=====================
# Create CNV policy, placement, and placement binding
#=====================
echo "[INFO] Creating CNV installation policy, placement (targeting ${#cluster_names[@]} cluster sets), and placement binding"
oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: install-cnv-operator
  namespace: ${policy_ns}
  annotations:
    policy.open-cluster-management.io/categories: ""
    policy.open-cluster-management.io/standards: ""
    policy.open-cluster-management.io/controls: ""
spec:
  disabled: false
  remediationAction: enforce
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1beta1
        kind: OperatorPolicy
        metadata:
          name: install-operator
        spec:
          remediationAction: enforce
          severity: critical
          complianceType: musthave
          subscription:
            name: kubevirt-hyperconverged
            namespace: openshift-cnv
            channel: stable
            source: redhat-operators
            sourceNamespace: openshift-marketplace
          upgradeApproval: Automatic
          versions:
          operatorGroup:
            name: openshift-cnv
            namespace: openshift-cnv
            targetNamespaces:
              - openshift-cnv
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
  namespace: ${policy_ns}
spec:
  tolerations:
    - key: cluster.open-cluster-management.io/unreachable
      operator: Exists
    - key: cluster.open-cluster-management.io/unavailable
      operator: Exists
  clusterSets:
${cluster_sets_yaml}---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: install-cnv-placement
  namespace: ${policy_ns}
placementRef:
  name: install-cnv-placement
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
subjects:
  - name: install-cnv-operator
    apiGroup: policy.open-cluster-management.io
    kind: Policy
EOF

#=====================
# Wait for CNV installation on all spoke clusters (in parallel)
#=====================
# Note: The OperatorPolicy installs the operator (which registers CRDs),
# and the ConfigurationPolicy creates the HyperConverged CR.
# We only need to wait for the final availability status on each spoke.

echo "[INFO] =========================================="
echo "[INFO] Waiting for CNV installation on ${#cluster_names[@]} spoke cluster(s)"
echo "[INFO] Timeout: ${wait_timeout_minutes} minutes per cluster"
echo "[INFO] =========================================="

# WaitForCNV - Waits for HyperConverged operator to become available on a spoke cluster
# Arguments:
#   $1 - cluster_name: Name of the cluster (for logging)
#   $2 - kubeconfig:   Path to the spoke cluster kubeconfig
#   $3 - result_file:  Path to write the exit code result
WaitForCNV() {
    typeset cluster_name="$1"
    typeset kubeconfig="$2"
    typeset result_file="$3"
    typeset start_time
    typeset deadline
    typeset cond

    start_time="$(date +%s)"
    deadline=$((start_time + wait_timeout_minutes * 60))

    echo "[INFO] [${cluster_name}] Waiting for HyperConverged CR to be created..."

    # Wait for the HyperConverged CR to exist (ensures operator and CRD are ready)
    while ! oc --kubeconfig="${kubeconfig}" -n openshift-cnv get hyperconverged kubevirt-hyperconverged >/dev/null 2>&1; do
        if (( $(date +%s) > deadline )); then
            echo "[ERROR] [${cluster_name}] Timeout waiting for HyperConverged CR to be created" >&2
            echo "1" > "${result_file}"
            return 1
        fi
        sleep "${poll_interval_seconds}"
    done
    echo "[INFO] [${cluster_name}] HyperConverged CR created"

    # Wait for the Available condition to be True
    echo "[INFO] [${cluster_name}] Waiting for HyperConverged operator to become Available..."
    while true; do
        cond="$(oc --kubeconfig="${kubeconfig}" -n openshift-cnv get hyperconverged kubevirt-hyperconverged \
            -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{end}' \
            2>/dev/null || echo "")"

        if [[ "${cond}" == "True" ]]; then
            echo "[SUCCESS] [${cluster_name}] HyperConverged operator is available"
            echo "0" > "${result_file}"
            return 0
        fi

        if (( $(date +%s) > deadline )); then
            echo "[ERROR] [${cluster_name}] Timeout waiting for HyperConverged operator to become available" >&2
            echo "1" > "${result_file}"
            return 1
        fi

        echo "[INFO] [${cluster_name}] Waiting for HyperConverged operator... (status: ${cond:-Unknown})"
        sleep "${poll_interval_seconds}"
    done
}

# Create temp directory for result files
typeset results_dir
results_dir="$(mktemp -d)"
trap 'rm -rf "${results_dir}"' EXIT

# Array to hold background PIDs
typeset -a pids=()

# Start waiting for all clusters in parallel
typeset result_file=""
for ((i = 0; i < ${#cluster_names[@]}; i++)); do
    idx=$((i + 1))
    cluster_name="${cluster_names[i]}"
    kc_file="${spoke_kubeconfigs[i]}"
    result_file="${results_dir}/cluster-${idx}.result"

    echo "[INFO] Starting CNV wait for cluster ${idx}: ${cluster_name}"
    WaitForCNV "${cluster_name}" "${kc_file}" "${result_file}" &
    pids+=($!)
done

echo "[INFO] Waiting for CNV installation to complete on all ${#pids[@]} cluster(s)..."

# Wait for all background processes and collect results
typeset failed_count=0
typeset wait_rc=0
typeset stored_rc=""
for ((i = 0; i < ${#pids[@]}; i++)); do
    idx=$((i + 1))
    cluster_name="${cluster_names[i]}"
    result_file="${results_dir}/cluster-${idx}.result"
    wait_rc=0

    # Wait for specific PID
    wait "${pids[i]}" || wait_rc=$?

    # Check result file for actual exit code
    if [[ -f "${result_file}" ]]; then
        stored_rc="$(cat "${result_file}")"
        if [[ "${stored_rc}" != "0" ]]; then
            echo "[ERROR] Cluster ${idx} (${cluster_name}) CNV installation failed" >&2
            ((++failed_count))
        fi
    elif [[ ${wait_rc} -ne 0 ]]; then
        echo "[ERROR] Cluster ${idx} (${cluster_name}) wait process failed with exit code: ${wait_rc}" >&2
        ((++failed_count))
    fi
done

#=====================
# Final summary
#=====================
echo "[INFO] =========================================="
if [[ ${failed_count} -eq 0 ]]; then
    echo "[SUCCESS] CNV installation via policy completed on all ${#cluster_names[@]} cluster(s)"
    for ((i = 0; i < ${#cluster_names[@]}; i++)); do
        echo "[INFO]   Cluster $((i+1)): ${cluster_names[i]} - CNV installed"
    done
else
    echo "[ERROR] CNV installation failed on ${failed_count}/${#cluster_names[@]} cluster(s)" >&2
    exit 1
fi
echo "[INFO] =========================================="
