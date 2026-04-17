#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

ODF_INSTALL_NAMESPACE=openshift-storage
ODF_OPERATOR_CHANNEL="${ODF_OPERATOR_CHANNEL:-'stable-4.12'}"
ODF_SUBSCRIPTION_NAME="${ODF_SUBSCRIPTION_NAME:-'odf-operator'}"
ODF_BACKEND_STORAGE_CLASS="${ODF_BACKEND_STORAGE_CLASS:-'gp3-csi'}"
ODF_VOLUME_SIZE="${ODF_VOLUME_SIZE:-100}Gi"
ODF_SUBSCRIPTION_SOURCE="${ODF_SUBSCRIPTION_SOURCE:-'redhat-operators'}"

# Make the masters schedulable so we have more capacity to run VMs
CONTROL_PLANE_TOPOLOGY=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}')
if [[ ${CONTROL_PLANE_TOPOLOGY} != "External" ]]
then
  oc patch scheduler cluster --type=json -p '[{ "op": "replace", "path": "/spec/mastersSchedulable", "value": true }]'
fi

ODF_CATALOG_SOURCE="${ODF_SUBSCRIPTION_SOURCE}"
if oc get packagemanifest -l "catalog=${ODF_SUBSCRIPTION_SOURCE}" -n openshift-marketplace -o name 2>/dev/null | grep -q 'odf-operator'; then
  echo "odf-operator package found in ${ODF_SUBSCRIPTION_SOURCE} catalog"
  ODF_OPERATOR_CHANNEL=$(oc get packagemanifest -l "catalog=${ODF_SUBSCRIPTION_SOURCE}" -n openshift-marketplace \
    -o jsonpath='{.items[?(@.metadata.name=="odf-operator")].status.channels[*].name}' | tr ' ' '\n' | sort -V | tail -1)
else
  echo "odf-operator package not found in ${ODF_SUBSCRIPTION_SOURCE} catalog, creating ODF 4.22 catalog source with ICSP"

  # Create ImageContentSourcePolicy for ODF 4.22
  echo "Creating ImageContentSourcePolicy for ODF repositories"
  oc create -f - <<EOF || true
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: df-repo-4.22.0
spec:
  repositoryDigestMirrors:
  - mirrors:
    - quay.io/rhceph-dev/odf4-ceph-volsync-plugin-mover-rhel9
    - brew.registry.redhat.io/odf4/ceph-volsync-plugin-mover-rhel9
    source: registry.redhat.io/odf4/ceph-volsync-plugin-mover-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-ceph-volsync-plugin-operator-bundle
    - brew.registry.redhat.io/odf4/ceph-volsync-plugin-operator-bundle
    source: registry.redhat.io/odf4/ceph-volsync-plugin-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-ceph-volsync-plugin-rhel9-operator
    - brew.registry.redhat.io/odf4/ceph-volsync-plugin-rhel9-operator
    source: registry.redhat.io/odf4/ceph-volsync-plugin-rhel9-operator
  - mirrors:
    - quay.io/rhceph-dev/odf4-cephcsi-operator-bundle
    - brew.registry.redhat.io/odf4/cephcsi-operator-bundle
    source: registry.redhat.io/odf4/cephcsi-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-cephcsi-rhel9-operator
    - brew.registry.redhat.io/odf4/cephcsi-rhel9-operator
    source: registry.redhat.io/odf4/cephcsi-rhel9-operator
  - mirrors:
    - quay.io/rhceph-dev/odf4-cephcsi-rhel9
    - brew.registry.redhat.io/odf4/cephcsi-rhel9
    source: registry.redhat.io/odf4/cephcsi-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-devicefinder-rhel9
    - brew.registry.redhat.io/odf4/devicefinder-rhel9
    source: registry.redhat.io/odf4/devicefinder-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-mcg-core-rhel9
    - brew.registry.redhat.io/odf4/mcg-core-rhel9
    source: registry.redhat.io/odf4/mcg-core-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-mcg-operator-bundle
    - brew.registry.redhat.io/odf4/mcg-operator-bundle
    source: registry.redhat.io/odf4/mcg-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-mcg-rhel9-operator
    - brew.registry.redhat.io/odf4/mcg-rhel9-operator
    source: registry.redhat.io/odf4/mcg-rhel9-operator
  - mirrors:
    - quay.io/rhceph-dev/odf4-ocs-client-console-rhel9
    - brew.registry.redhat.io/odf4/ocs-client-console-rhel9
    source: registry.redhat.io/odf4/ocs-client-console-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-ocs-client-operator-bundle
    - brew.registry.redhat.io/odf4/ocs-client-operator-bundle
    source: registry.redhat.io/odf4/ocs-client-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-ocs-client-rhel9-operator
    - brew.registry.redhat.io/odf4/ocs-client-rhel9-operator
    source: registry.redhat.io/odf4/ocs-client-rhel9-operator
  - mirrors:
    - quay.io/rhceph-dev/odf4-ocs-metrics-exporter-rhel9
    - brew.registry.redhat.io/odf4/ocs-metrics-exporter-rhel9
    source: registry.redhat.io/odf4/ocs-metrics-exporter-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-ocs-operator-bundle
    - brew.registry.redhat.io/odf4/ocs-operator-bundle
    source: registry.redhat.io/odf4/ocs-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-ocs-rhel9-operator
    - brew.registry.redhat.io/odf4/ocs-rhel9-operator
    source: registry.redhat.io/odf4/ocs-rhel9-operator
  - mirrors:
    - quay.io/rhceph-dev/odf4-ocs-tls-profiles-operator-bundle
    - brew.registry.redhat.io/odf4/ocs-tls-profiles-operator-bundle
    source: registry.redhat.io/odf4/ocs-tls-profiles-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-blackbox-exporter-rhel9
    - brew.registry.redhat.io/odf4/odf-blackbox-exporter-rhel9
    source: registry.redhat.io/odf4/odf-blackbox-exporter-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-cloudnative-pg-rhel9-operator
    - brew.registry.redhat.io/odf4/odf-cloudnative-pg-rhel9-operator
    source: registry.redhat.io/odf4/odf-cloudnative-pg-rhel9-operator
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-console-rhel9
    - brew.registry.redhat.io/odf4/odf-console-rhel9
    source: registry.redhat.io/odf4/odf-console-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-cosi-sidecar-rhel9
    - brew.registry.redhat.io/odf4/odf-cosi-sidecar-rhel9
    source: registry.redhat.io/odf4/odf-cosi-sidecar-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-csi-addons-operator-bundle
    - brew.registry.redhat.io/odf4/odf-csi-addons-operator-bundle
    source: registry.redhat.io/odf4/odf-csi-addons-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-csi-addons-rhel9-operator
    - brew.registry.redhat.io/odf4/odf-csi-addons-rhel9-operator
    source: registry.redhat.io/odf4/odf-csi-addons-rhel9-operator
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-csi-addons-sidecar-rhel9
    - brew.registry.redhat.io/odf4/odf-csi-addons-sidecar-rhel9
    source: registry.redhat.io/odf4/odf-csi-addons-sidecar-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-dependencies-operator-bundle
    - brew.registry.redhat.io/odf4/odf-dependencies-operator-bundle
    source: registry.redhat.io/odf4/odf-dependencies-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-drbd-rhel9
    - brew.registry.redhat.io/odf4/odf-drbd-rhel9
    source: registry.redhat.io/odf4/odf-drbd-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-external-snapshotter-operator-bundle
    - brew.registry.redhat.io/odf4/odf-external-snapshotter-operator-bundle
    source: registry.redhat.io/odf4/odf-external-snapshotter-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-external-snapshotter-rhel9-operator
    - brew.registry.redhat.io/odf4/odf-external-snapshotter-rhel9-operator
    source: registry.redhat.io/odf4/odf-external-snapshotter-rhel9-operator
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-external-snapshotter-sidecar-rhel9
    - brew.registry.redhat.io/odf4/odf-external-snapshotter-sidecar-rhel9
    source: registry.redhat.io/odf4/odf-external-snapshotter-sidecar-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-multicluster-console-rhel9
    - brew.registry.redhat.io/odf4/odf-multicluster-console-rhel9
    source: registry.redhat.io/odf4/odf-multicluster-console-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-multicluster-operator-bundle
    - brew.registry.redhat.io/odf4/odf-multicluster-operator-bundle
    source: registry.redhat.io/odf4/odf-multicluster-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-multicluster-rhel9-operator
    - brew.registry.redhat.io/odf4/odf-multicluster-rhel9-operator
    source: registry.redhat.io/odf4/odf-multicluster-rhel9-operator
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-must-gather-rhel9
    - brew.registry.redhat.io/odf4/odf-must-gather-rhel9
    source: registry.redhat.io/odf4/odf-must-gather-rhel9
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-operator-bundle
    - brew.registry.redhat.io/odf4/odf-operator-bundle
    source: registry.redhat.io/odf4/odf-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-prometheus-operator-bundle
    - brew.registry.redhat.io/odf4/odf-prometheus-operator-bundle
    source: registry.redhat.io/odf4/odf-prometheus-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-odf-rhel9-operator
    - brew.registry.redhat.io/odf4/odf-rhel9-operator
    source: registry.redhat.io/odf4/odf-rhel9-operator
  - mirrors:
    - quay.io/rhceph-dev/odf4-odr-cluster-operator-bundle
    - brew.registry.redhat.io/odf4/odr-cluster-operator-bundle
    source: registry.redhat.io/odf4/odr-cluster-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-odr-hub-operator-bundle
    - brew.registry.redhat.io/odf4/odr-hub-operator-bundle
    source: registry.redhat.io/odf4/odr-hub-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-odr-recipe-operator-bundle
    - brew.registry.redhat.io/odf4/odr-recipe-operator-bundle
    source: registry.redhat.io/odf4/odr-recipe-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-odr-rhel9-operator
    - brew.registry.redhat.io/odf4/odr-rhel9-operator
    source: registry.redhat.io/odf4/odr-rhel9-operator
  - mirrors:
    - quay.io/rhceph-dev/odf4-rook-ceph-operator-bundle
    - brew.registry.redhat.io/odf4/rook-ceph-operator-bundle
    source: registry.redhat.io/odf4/rook-ceph-operator-bundle
  - mirrors:
    - quay.io/rhceph-dev/odf4-rook-ceph-rhel9-operator
    - brew.registry.redhat.io/odf4/rook-ceph-rhel9-operator
    source: registry.redhat.io/odf4/rook-ceph-rhel9-operator
  - mirrors:
    - quay.io/rhceph-dev/openshift-ose-csi-external-attacher-rhel9
    - brew.registry.redhat.io/openshift4/ose-csi-external-attacher-rhel9
    source: registry.redhat.io/openshift4/ose-csi-external-attacher-rhel9
  - mirrors:
    - quay.io/rhceph-dev/openshift-ose-csi-external-provisioner-rhel9
    - brew.registry.redhat.io/openshift4/ose-csi-external-provisioner-rhel9
    source: registry.redhat.io/openshift4/ose-csi-external-provisioner-rhel9
  - mirrors:
    - quay.io/rhceph-dev/openshift-ose-csi-external-resizer-rhel9
    - brew.registry.redhat.io/openshift4/ose-csi-external-resizer-rhel9
    source: registry.redhat.io/openshift4/ose-csi-external-resizer-rhel9
  - mirrors:
    - quay.io/rhceph-dev/openshift-ose-csi-external-snapshot-metadata-rhel9
    - brew.registry.redhat.io/openshift4/ose-csi-external-snapshot-metadata-rhel9
    source: registry.redhat.io/openshift4/ose-csi-external-snapshot-metadata-rhel9
  - mirrors:
    - quay.io/rhceph-dev/openshift-ose-csi-external-snapshotter-rhel9
    - brew.registry.redhat.io/openshift4/ose-csi-external-snapshotter-rhel9
    source: registry.redhat.io/openshift4/ose-csi-external-snapshotter-rhel9
  - mirrors:
    - quay.io/rhceph-dev/openshift-ose-csi-node-driver-registrar-rhel9
    - brew.registry.redhat.io/openshift4/ose-csi-node-driver-registrar-rhel9
    source: registry.redhat.io/openshift4/ose-csi-node-driver-registrar-rhel9
  - mirrors:
    - quay.io/rhceph-dev/openshift-ose-kube-rbac-proxy-rhel9
    - brew.registry.redhat.io/openshift4/ose-kube-rbac-proxy-rhel9
    source: registry.redhat.io/openshift4/ose-kube-rbac-proxy-rhel9
  - mirrors:
    - quay.io/rhceph-dev/openshift-ose-oauth-proxy-rhel9
    - brew.registry.redhat.io/openshift4/ose-oauth-proxy-rhel9
    source: registry.redhat.io/openshift4/ose-oauth-proxy-rhel9
  - mirrors:
    - quay.io/rhceph-dev/openshift-ose-prometheus-alertmanager-rhel9
    - brew.registry.redhat.io/openshift4/ose-prometheus-alertmanager-rhel9
    source: registry.redhat.io/openshift4/ose-prometheus-alertmanager-rhel9
  - mirrors:
    - quay.io/rhceph-dev/openshift-ose-prometheus-config-reloader-rhel9
    - brew.registry.redhat.io/openshift4/ose-prometheus-config-reloader-rhel9
    source: registry.redhat.io/openshift4/ose-prometheus-config-reloader-rhel9
  - mirrors:
    - quay.io/rhceph-dev/openshift-ose-prometheus-rhel9-operator
    - brew.registry.redhat.io/openshift4/ose-prometheus-rhel9-operator
    source: registry.redhat.io/openshift4/ose-prometheus-rhel9-operator
  - mirrors:
    - quay.io/rhceph-dev/openshift-ose-prometheus-rhel9
    - brew.registry.redhat.io/openshift4/ose-prometheus-rhel9
    source: registry.redhat.io/openshift4/ose-prometheus-rhel9
  - mirrors:
    - quay.io/rhceph-dev/rhceph-9-rhel9
    - brew.registry.redhat.io/rhceph/rhceph-9-rhel9
    source: registry.redhat.io/rhceph/rhceph-9-rhel9
  - mirrors:
    - quay.io/rhceph-dev/rhel9-postgresql-16
    - brew.registry.redhat.io/rhel9/postgresql-16
    source: registry.redhat.io/rhel9/postgresql-16
EOF

  # Create ODF CatalogSource
  echo "Creating ODF 4.22 CatalogSource"
  oc apply -f - <<EOCATALOG
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  labels:
    ocs-operator-internal: 'true'
  name: redhat-operators-odf
  namespace: openshift-marketplace
spec:
  displayName: Openshift Data Foundation
  icon:
    base64data: PHN2ZyBpZD0iTGF5ZXJfMSIgZGF0YS1uYW1lPSJMYXllciAxIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxOTIgMTQ1Ij48ZGVmcz48c3R5bGU+LmNscy0xe2ZpbGw6I2UwMDt9PC9zdHlsZT48L2RlZnM+PHRpdGxlPlJlZEhhdC1Mb2dvLUhhdC1Db2xvcjwvdGl0bGU+PHBhdGggZD0iTTE1Ny43Nyw2Mi42MWExNCwxNCwwLDAsMSwuMzEsMy40MmMwLDE0Ljg4LTE4LjEsMTcuNDYtMzAuNjEsMTcuNDZDNzguODMsODMuNDksNDIuNTMsNTMuMjYsNDIuNTMsNDRhNi40Myw2LjQzLDAsMCwxLC4yMi0xLjk0bC0zLjY2LDkuMDZhMTguNDUsMTguNDUsMCwwLDAtMS41MSw3LjMzYzAsMTguMTEsNDEsNDUuNDgsODcuNzQsNDUuNDgsMjAuNjksMCwzNi40My03Ljc2LDM2LjQzLTIxLjc3LDAtMS4wOCwwLTEuOTQtMS43My0xMC4xM1oiLz48cGF0aCBjbGFzcz0iY2xzLTEiIGQ9Ik0xMjcuNDcsODMuNDljMTIuNTEsMCwzMC42MS0yLjU4LDMwLjYxLTE3LjQ2YTE0LDE0LDAsMCwwLS4zMS0zLjQybC03LjQ1LTMyLjM2Yy0xLjcyLTcuMTItMy4yMy0xMC4zNS0xNS43My0xNi42QzEyNC44OSw4LjY5LDEwMy43Ni41LDk3LjUxLjUsOTEuNjkuNSw5MCw4LDgzLjA2LDhjLTYuNjgsMC0xMS42NC01LjYtMTcuODktNS42LTYsMC05LjkxLDQuMDktMTIuOTMsMTIuNSwwLDAtOC40MSwyMy43Mi05LjQ5LDI3LjE2QTYuNDMsNi40MywwLDAsMCw0Mi41Myw0NGMwLDkuMjIsMzYuMywzOS40NSw4NC45NCwzOS40NU0xNjAsNzIuMDdjMS43Myw4LjE5LDEuNzMsOS4wNSwxLjczLDEwLjEzLDAsMTQtMTUuNzQsMjEuNzctMzYuNDMsMjEuNzdDNzguNTQsMTA0LDM3LjU4LDc2LjYsMzcuNTgsNTguNDlhMTguNDUsMTguNDUsMCwwLDEsMS41MS03LjMzQzIyLjI3LDUyLC41LDU1LC41LDc0LjIyYzAsMzEuNDgsNzQuNTksNzAuMjgsMTMzLjY1LDcwLjI4LDQ1LjI4LDAsNTYuNy0yMC40OCw1Ni43LTM2LjY1LDAtMTIuNzItMTEtMjcuMTYtMzAuODMtMzUuNzgiLz48L3N2Zz4=
    mediatype: image/svg+xml
  image: quay.io/rhceph-dev/ocs-registry:latest-stable-4.22
  priority: 100
  publisher: Red Hat
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOCATALOG

  # Update global pull secret to include brew.registry.redhat.io
  echo "Updating global pull secret with brew.registry.redhat.io credentials"
  oc patch secret pull-secret -n openshift-config --type=json -p="[{\"op\": \"add\", \"path\": \"/data/.dockerconfigjson\", \"value\": \"$(cat /etc/hypershift-agent-ibmz-credentials/odf-nightly-pull-secret)\"}]" || true

  ODF_CATALOG_SOURCE="redhat-operators-odf"
  
  echo "Waiting for ODF catalog source to become ready"
  for ((i=1; i <= 60; i++)); do
    STATE=$(oc get catalogsource "${ODF_CATALOG_SOURCE}" -n openshift-marketplace \
      -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
    if [[ "${STATE}" == "READY" ]]; then
      echo "ODF catalog source is ready"
      break
    fi
    echo "Try ${i}/60: catalog source not ready yet (state: ${STATE}). Retrying in 10s"
    sleep 10
  done

  echo "Waiting for odf-operator packagemanifest to appear in ODF catalog"
  for ((i=1; i <= 60; i++)); do
    if oc get packagemanifest -l "catalog=${ODF_CATALOG_SOURCE}" -n openshift-marketplace -o name 2>/dev/null | grep -q 'odf-operator'; then
      echo "odf-operator package found in ODF catalog"
      break
    fi
    echo "Try ${i}/60: odf-operator not available yet. Retrying in 10s"
    sleep 10
  done

  ODF_OPERATOR_CHANNEL=$(oc get packagemanifest -l "catalog=${ODF_CATALOG_SOURCE}" -n openshift-marketplace \
    -o jsonpath='{.items[?(@.metadata.name=="odf-operator")].status.channels[*].name}' | tr ' ' '\n' | sort -V | tail -1)
fi

ODF_SUBSCRIPTION_SOURCE="${ODF_CATALOG_SOURCE}"
echo "Using catalog source: ${ODF_SUBSCRIPTION_SOURCE}, channel: ${ODF_OPERATOR_CHANNEL}"

echo "Installing ODF from ${ODF_OPERATOR_CHANNEL} into ${ODF_INSTALL_NAMESPACE}"
# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${ODF_INSTALL_NAMESPACE}"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  annotations:
    olm.providedAPIs: BackingStore.v1alpha1.noobaa.io,BucketClass.v1alpha1.noobaa.io,CSIAddonsNode.v1alpha1.csiaddons.openshift.io,CephBlockPool.v1.ceph.rook.io,CephBlockPoolRadosNamespace.v1.ceph.rook.io,CephBucketNotification.v1.ceph.rook.io,CephBucketTopic.v1.ceph.rook.io,CephClient.v1.ceph.rook.io,CephCluster.v1.ceph.rook.io,CephFilesystem.v1.ceph.rook.io,CephFilesystemMirror.v1.ceph.rook.io,CephFilesystemSubVolumeGroup.v1.ceph.rook.io,CephNFS.v1.ceph.rook.io,CephObjectRealm.v1.ceph.rook.io,CephObjectStore.v1.ceph.rook.io,CephObjectStoreUser.v1.ceph.rook.io,CephObjectZone.v1.ceph.rook.io,CephObjectZoneGroup.v1.ceph.rook.io,CephRBDMirror.v1.ceph.rook.io,NamespaceStore.v1alpha1.noobaa.io,NetworkFence.v1alpha1.csiaddons.openshift.io,NooBaa.v1alpha1.noobaa.io,NooBaaAccount.v1alpha1.noobaa.io,OCSInitialization.v1.ocs.openshift.io,ObjectBucket.v1alpha1.objectbucket.io,ObjectBucketClaim.v1alpha1.objectbucket.io,ReclaimSpaceCronJob.v1alpha1.csiaddons.openshift.io,ReclaimSpaceJob.v1alpha1.csiaddons.openshift.io,StorageClassClaim.v1alpha1.ocs.openshift.io,StorageCluster.v1.ocs.openshift.io,StorageConsumer.v1alpha1.ocs.openshift.io,StorageSystem.v1alpha1.odf.openshift.io,VolumeReplication.v1alpha1.replication.storage.openshift.io,VolumeReplicationClass.v1alpha1.replication.storage.openshift.io
  name: "${ODF_INSTALL_NAMESPACE}-operator-group"
  namespace: "${ODF_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${ODF_INSTALL_NAMESPACE}\" | sed "s|,|\"\n  - \"|g")
EOF

echo "subscribe to the operator subscription name: $ODF_SUBSCRIPTION_NAME, namespace: $ODF_INSTALL_NAMESPACE, channel $ODF_OPERATOR_CHANNEL"
SUB=$(
    cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $ODF_SUBSCRIPTION_NAME
  namespace: $ODF_INSTALL_NAMESPACE
spec:
  channel: $ODF_OPERATOR_CHANNEL
  installPlanApproval: Automatic
  name: $ODF_SUBSCRIPTION_NAME
  source: $ODF_SUBSCRIPTION_SOURCE
  sourceNamespace: openshift-marketplace
EOF
)

RETRIES=90
echo "Waiting for CSV to be available from operator group"
for ((i=1; i <= $RETRIES; i++)); do
    CSV=$(oc -n "$ODF_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n "$ODF_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"
            break
	else
	   oc -n "$ODF_INSTALL_NAMESPACE" get csv "$CSV" -o yaml --ignore-not-found
        fi
    else
      echo "Try ${i}/${RETRIES}: ODF is not deployed yet. Checking again in 10 seconds"
      oc -n "$ODF_INSTALL_NAMESPACE" get subscription "$SUB" -o yaml --ignore-not-found
    fi
    sleep 10
done

echo "Waiting for noobaa-operator"
for ((i=1; i <= $RETRIES; i++)); do
    NOOBAA=$(oc -n "$ODF_INSTALL_NAMESPACE" get deployment noobaa-operator --ignore-not-found)
    if [[ -n "$NOOBAA" ]]; then
       echo "Found noobaa operator"
       break
    fi
    sleep 10
done

oc wait deployment noobaa-operator \
--namespace="${ODF_INSTALL_NAMESPACE}" \
--for=condition='Available' \
--timeout='5m'

echo "Preparing nodes"
oc label nodes cluster.ocs.openshift.io/openshift-storage='' \
  --selector='node-role.kubernetes.io/worker' --overwrite

echo "Assigning rack topology labels"
nodes=($(oc get nodes -l node-role.kubernetes.io/worker -o name))
i=0
for node in "${nodes[@]}"; do
  oc label $node topology.rook.io/rack="rack${i}" --overwrite
  ((i++))
done

echo "Wait for StorageCluster CRD to be created"
timeout 30m bash -c '
  until oc get crd storageclusters.ocs.openshift.io &>/dev/null; do
    sleep 5
  done
'

echo "Create StorageCluster"
cat <<EOF | oc apply -f -
kind: StorageCluster
apiVersion: ocs.openshift.io/v1
metadata:
 name: ocs-storagecluster
 namespace: $ODF_INSTALL_NAMESPACE
spec:
  resources:
    mon:
      requests:
        cpu: "0"
        memory: "0"
    mgr:
      requests:
        cpu: "0"
        memory: "0"
  monDataDirHostPath: /var/lib/rook
  managedResources:
    cephFilesystems: {}
    cephObjectStores: {}
  multiCloudGateway:
    reconcileStrategy: ignore
  storageDeviceSets:
    - name: ocs-deviceset
      count: 3
      dataPVCTemplate:
        spec:
          storageClassName: $ODF_BACKEND_STORAGE_CLASS
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: $ODF_VOLUME_SIZE
          volumeMode: Block
      placement: {}
      portable: false
      replica: 1
      resources:
        requests:
          cpu: "0"
          memory: "0"
EOF

echo "Wait for StorageCluster to be deployed"
oc wait "storagecluster.ocs.openshift.io/ocs-storagecluster"  \
   -n $ODF_INSTALL_NAMESPACE --for=condition='Available' --timeout='30m'

echo "ODF/OCS Operator is deployed successfully"
ODF_VIRT_SC=ocs-storagecluster-ceph-rbd-virtualization

echo "Wait for the storage class ${ODF_VIRT_SC} to be created"
timeout 30m bash -c "
  until oc get storageclass ${ODF_VIRT_SC} &>/dev/null; do
    sleep 5
  done
" || true

oc get sc

# Setting ocs-storagecluster-ceph-rbd-virtualization the default storage class
for item in $(oc get sc --no-headers | awk '{print $1}'); do
	oc annotate --overwrite sc $item storageclass.kubernetes.io/is-default-class='false'
done
oc annotate --overwrite sc ${ODF_VIRT_SC} storageclass.kubernetes.io/is-default-class='true'
oc annotate --overwrite volumesnapshotclass ocs-storagecluster-rbdplugin-snapclass snapshot.storage.kubernetes.io/is-default-class='true'
echo "ocs-storagecluster-ceph-rbd is set as default storage class"

# Ensure that the csi-snapshot-controller is restarted so that it picks up the annotation on the volume snapshot class
replica_count=$(oc get deployment -n openshift-cluster-storage-operator csi-snapshot-controller -o=jsonpath='{@.spec.replicas}')
echo "Current replica count $replica_count"

if [[ $(oc get csisnapshotcontroller cluster -o=jsonpath='{@.spec.managementState}') ]]; then
oc patch csisnapshotcontroller cluster --type=json -p='[{"op": "remove", "path": "/spec/managementState"}]' -n openshift-cluster-storage-operator
fi
oc scale deployment -n openshift-cluster-storage-operator csi-snapshot-controller --replicas=0

RETRIES=60
echo "Waiting for pods to be gone"
for ((i=1; i <= $RETRIES; i++)); do
    availableReplicas=$(oc get deployment -n openshift-cluster-storage-operator csi-snapshot-controller -o=jsonpath='{@.status.availableReplicas}')
    if [[ -z "$availableReplicas" ]]; then
        echo "No csi snapshot controller replicas left"
        break
    else
      echo "Still $availableReplicas replicas available"
    fi
    sleep 1
done

echo "managing deployment again, will restore to needed value"
oc patch csisnapshotcontroller cluster --type=json -p='[{"op": "add", "path": "/spec/managementState", "value": "Managed"}]' -n openshift-cluster-storage-operator
echo "waiting for deployment to be ready"
oc rollout status deployment/csi-snapshot-controller -n openshift-cluster-storage-operator
