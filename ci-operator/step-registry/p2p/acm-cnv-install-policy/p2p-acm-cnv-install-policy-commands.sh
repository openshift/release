#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

cluster_name="$(cat "${SHARED_DIR}/managed.cluster.name")"
policy_ns="install-cnv"

# create policy namespace
oc create namespace $policy_ns

  
oc create -f - <<EOF
        apiVersion: cluster.open-cluster-management.io/v1beta2
        kind: ManagedClusterSetBinding
        metadata:
          name: ${cluster_name}-set
          namespace: ${policy_ns}
        spec:
          clusterSet: ${cluster_name}-set
EOF

# create CNV policy and apply it to the clustersset, create the placement and placementbinding for the policy
oc create -f - <<EOF
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
    - ${cluster_name}-set
---
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

export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"
wait_timeout=20
crd_start_time=$(date +%s)
crd_timeout=$(( wait_timeout * 60 ))
has_timed_out() {
  current_time=$(date +%s)
  (( current_time - crd_start_time >= crd_timeout ))
}

echo  "waiting for hyperconverged CRD to be registered"
while ! oc get crd hyperconvergeds.hco.kubevirt.io >/dev/null 2>&1; do
  if has_timed_out; then
    echo " Timed out waiting for CRD hyperconvergeds.hco.kubevirt.io"
    exit 1
  fi
  sleep 30
done 
echo "CRD  hyperconvergeds.hco.kubevirt.io is registered"

echo  "waiting for hyperconverged CR kubevirt-hyperconverged to be created"
while ! oc -n openshift-cnv get hyperconverged kubevirt-hyperconverged >/dev/null 2>&1; do
  if has_timed_out; then
    echo " Timed out waiting for HCO CR"
    exit 1
  fi
  sleep 30
done 
echo "CR kubevirt-hyperconverged is registered"

while true; do
  cond=$(oc -n openshift-cnv get hyperconverged kubevirt-hyperconverged \
           -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{end}' \
           2>/dev/null || echo "")
  if [[ "$cond" == "True" ]]; then
    echo " HCO is available"
    break
  fi
  if has_timed_out; then
    echo "Timed out waiting for HCO to become available"
    exit 1
  fi
  sleep 30
done 


