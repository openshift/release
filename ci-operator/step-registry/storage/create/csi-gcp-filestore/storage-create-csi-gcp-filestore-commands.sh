#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

CLUSTER_NAME="$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)"
NETWORK_NAME="$CLUSTER_NAME-network"
export CLUSTER_NAME
export NETWORK_NAME
export STORAGECLASS_LOCATION=${SHARED_DIR}/filestore-sc.yaml
export MANIFEST_LOCATION=${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# Create StorageClass
echo "Creating a StorageClass"
cat <<EOF >>$STORAGECLASS_LOCATION
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: filestore-csi
provisioner: filestore.csi.storage.gke.io
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  network: $NETWORK_NAME
  labels: kubernetes-io-cluster-$CLUSTER_NAME=owned
EOF

echo "Using StorageClass file ${STORAGECLASS_LOCATION}"
cat ${STORAGECLASS_LOCATION}

oc create -f ${STORAGECLASS_LOCATION}
echo "Created StorageClass from file ${STORAGECLASS_LOCATION}"

oc create -f - <<EOF
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
    name: filestore.csi.storage.gke.io
spec:
  managementState: Managed
EOF

echo "Created ClusterCSIDriver object"

# Create test manifest
echo "Creating a manifest file"
cat <<EOF >>$MANIFEST_LOCATION
ShortName: filestore-csi
StorageClass:
  FromExistingClassName: filestore-csi
SnapshotClass:
  FromName: true
DriverInfo:
  Name: filestore.csi.storage.gke.io
  SupportedMountOption:
    sync: {}
  SupportedSizeRange:
    Min: 1Ti
    Max: 63.9Ti
  Capabilities:
    persistence: true
    exec: true
    RWX: true
    controllerExpansion: true
    snapshotDataSource: true
    multipods: true
    multiplePVsSameID: true
# Values taken from https://github.com/kubernetes-sigs/gcp-filestore-csi-driver/blob/fa2463561c2f19e253a30d172e067e2f8628fa88/test/k8s-integration/driver-config.go#L32-L41
# and adjusted to our CI experience.
Timeouts:
  PodStart: 25m
  PodStartSlow: 30m
  ClaimProvision: 25m
  PVCreate: 25m
  PVDelete: 25m
  DataSourceProvision: 25m
  SnapshotCreate: 25m
EOF

echo "Using manifest file ${MANIFEST_LOCATION}"
cat ${MANIFEST_LOCATION}
