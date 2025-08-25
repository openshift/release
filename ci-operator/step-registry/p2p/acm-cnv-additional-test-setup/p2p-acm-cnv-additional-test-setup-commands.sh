#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail



cp -L $KUBECONFIG /tmp/kubeconfig

export KUBECONFIG=/tmp/kubeconfig

oc create -f - <<EOF
        apiVersion: cluster.open-cluster-management.io/v1beta2
        kind: ManagedClusterSet
        metadata:
          name: managed-cluster-set
        spec: {}

EOF
 
oc create -f - <<EOF
        apiVersion: cluster.open-cluster-management.io/v1beta2
        kind: ManagedClusterSetBinding
        metadata:
          name: managed-cluster-set
          namespace: ocm
        spec:
          clusterSet: managed-cluster-set
EOF


oc label managedcluster local-cluster cluster.open-cluster-management.io/clusterset=managed-cluster-set --overwrite



AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"


if [[ -f "${AWSCRED}" ]]; then

  AWS_ACCESS_KEY_ID=$(cat "${AWSCRED}" | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
  AWS_SECRET_ACCESS_KEY=$(cat "${AWSCRED}" | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)

  oc create -f - <<EOF
          apiVersion: v1
          kind: Secret
          type: Opaque
          metadata:
            name: acm-aws-secret
            namespace: ocm
            labels:
              cluster.open-cluster-management.io/type: aws
              cluster.open-cluster-management.io/credentials: ""
          stringData:
            aws_access_key_id: "${AWS_ACCESS_KEY_ID}"
            aws_secret_access_key: "${AWS_SECRET_ACCESS_KEY}"
            baseDomain: "${BASE_DOMAIN}"
            pullSecret: "$(cat "${CLUSTER_PROFILE_DIR}/config.json")"
            ssh-privatekey:|-
             "$(cat "${CLUSTER_PROFILE_DIR}/ssh-privatekey")"
            ssh-publickey:|-
             "$(cat "${CLUSTER_PROFILE_DIR}/ssh-publickey")"
            httpProxy: ""
            httpsProxy: ""
            noProxy: ""
            additionalTrustBundle: ""
EOF

  echo "secret created"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi



oc create -f - <<EOF
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: install-cnv
  namespace: ocm
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
  namespace: ocm
spec:
  tolerations:
    - key: cluster.open-cluster-management.io/unreachable
      operator: Exists
    - key: cluster.open-cluster-management.io/unavailable
      operator: Exists
  clusterSets:
    - managed-cluster-set
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: install-cnv-placement
  namespace: ocm
placementRef:
  name: install-cnv-placement
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
subjects:
  - name: install-cnv
    apiGroup: policy.open-cluster-management.io
    kind: Policy

EOF

# oc wait HyperConverged -n openshift-cnv kubevirt-hyperconverged --for=condition=Available --timeout=20m

sleep 9000