#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

FUSION_ACCESS_STORAGE_SCALE_VERSION="${FUSION_ACCESS_STORAGE_SCALE_VERSION:-v5.2.3.1}"
FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"
STORAGE_SCALE_CLIENT_CPU="${STORAGE_SCALE_CLIENT_CPU:-2}"
STORAGE_SCALE_CLIENT_MEMORY="${STORAGE_SCALE_CLIENT_MEMORY:-4Gi}"
STORAGE_SCALE_STORAGE_CPU="${STORAGE_SCALE_STORAGE_CPU:-2}"
STORAGE_SCALE_STORAGE_MEMORY="${STORAGE_SCALE_STORAGE_MEMORY:-8Gi}"

echo "Starting Fusion Access Operator deployment..."
echo "Version: ${FUSION_ACCESS_STORAGE_SCALE_VERSION}"
echo "Namespace: ${FUSION_ACCESS_NAMESPACE}"
echo "Storage Scale Namespace: ${FUSION_ACCESS_NAMESPACE}"

IBM_ENTITLEMENT_KEY="$(cat "/var/run/secrets/ibm-entitlement-key")"
FUSION_PULL_SECRET_EXTRA="$(cat "/var/run/secrets/fusion-pullsecret-extra")"

oc new-project "${FUSION_ACCESS_NAMESPACE}"
oc create secret -n "${FUSION_ACCESS_NAMESPACE}" generic fusion-pullsecret --from-literal=ibm-entitlement-key="${IBM_ENTITLEMENT_KEY}" --dry-run=client -o yaml | oc apply -f -

sleep 7200 # debugging

oc apply -f=- <<EOF
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: storage-scale-operator-group
  namespace: ${FUSION_ACCESS_NAMESPACE}
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: test-fusion-access-operator
  namespace: openshift-marketplace
spec:
  displayName: Test Storage Scale Operator
  sourceType: grpc
  image: "quay.io/openshift-storage-scale/openshift-fusion-access-catalog:stable"
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-fusion-access-operator
  namespace: ${FUSION_ACCESS_NAMESPACE}
spec:
  channel: alpha
  installPlanApproval: Automatic
  name: openshift-fusion-access-operator
  source: test-fusion-access-operator
  sourceNamespace: openshift-marketplace
---
apiVersion: v1
kind: Secret
metadata:
  name: fusion-pullsecret-extra
  namespace: ${FUSION_ACCESS_NAMESPACE}
stringData:
  .dockerconfigjson: |
    {
      "quay.io/openshift-storage-scale": {
        "auth": "${FUSION_PULL_SECRET_EXTRA}",
        "email": ""
      }
    }
type: kubernetes.io/dockerconfigjson
---
apiVersion: fusion.storage.openshift.io/v1alpha1
kind: FusionAccess
metadata:
  name: fusionaccess-object
  namespace: ${FUSION_ACCESS_NAMESPACE}
spec:
  storageScaleVersion: ${FUSION_ACCESS_STORAGE_SCALE_VERSION}
  storageDeviceDiscovery:
    create: true
---
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Cluster
metadata:
  name: ibm-spectrum-scale
  namespace: ibm-spectrum-scale
spec:
  pmcollector:
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
  daemon:
    nsdDevicesConfig:
      localDevicePaths:
      - devicePath: /dev/disk/by-id/*
        deviceType: generic
    clusterProfile:
      controlSetxattrImmutableSELinux: "yes"
      enforceFilesetQuotaOnRoot: "yes"
      ignorePrefetchLUNCount: "yes"
      initPrefetchBuffers: "128"
      maxblocksize: 16M
      prefetchPct: "25"
      prefetchTimeout: "30"
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
    roles:
    - name: client
      resources:
        cpu: "${STORAGE_SCALE_CLIENT_CPU}"
        memory: ${STORAGE_SCALE_CLIENT_MEMORY}
    - name: storage
      resources:
        cpu: "${STORAGE_SCALE_STORAGE_CPU}"
        memory: ${STORAGE_SCALE_STORAGE_MEMORY}
  license:
    accept: true
    license: data-management
EOF

oc label nodes -l node-role.kubernetes.io/worker "scale.spectrum.ibm.com/role=storage"