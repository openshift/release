#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail



cp -L $KUBECONFIG /tmp/kubeconfig

export KUBECONFIG=/tmp/kubeconfig

CLUSTER_NAME="$(cat "${SHARED_DIR}/managed.cluster.name")"
POLICY_NS=${POLICY_NS:-"install-cnv"}

oc create namespace $POLICY_NS

# oc create -f - <<EOF
#         apiVersion: cluster.open-cluster-management.io/v1beta2
#         kind: ManagedClusterSet
#         metadata:
#           name: managed-cluster-set
#         spec: {}

# EOF
 
oc create -f - <<EOF
        apiVersion: cluster.open-cluster-management.io/v1beta2
        kind: ManagedClusterSetBinding
        metadata:
          name: ${CLUSTER_NAME}-set
          namespace: ${POLICY_NS}
        spec:
          clusterSet: ${CLUSTER_NAME}-set
EOF
# oc label managedcluster local-cluster cluster.open-cluster-management.io/clusterset=managed-cluster-set --overwrite

oc create -f - <<EOF
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: install-cnv-operator
  namespace: ${POLICY_NS}
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
  namespace: ${POLICY_NS}
spec:
  tolerations:
    - key: cluster.open-cluster-management.io/unreachable
      operator: Exists
    - key: cluster.open-cluster-management.io/unavailable
      operator: Exists
  clusterSets:
    - ${CLUSTER_NAME}-set
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: install-cnv-placement
  namespace: ${POLICY_NS}
placementRef:
  name: install-cnv-placement
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
subjects:
  - name: install-cnv-operator
    apiGroup: policy.open-cluster-management.io
    kind: Policy

EOF

sleep 900

oc --kubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig" wait hyperconverged -n openshift-cnv kubevirt-hyperconverged --for=condition=Available --timeout=20m

