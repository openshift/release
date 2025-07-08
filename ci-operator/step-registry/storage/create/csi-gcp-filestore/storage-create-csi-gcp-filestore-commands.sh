#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_NAME="$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)"
if [[ -s "${SHARED_DIR}/xpn.json" ]]
then
	echo "Reading variables from 'xpn_project_setting.json'..."
	cat ${CLUSTER_PROFILE_DIR}/xpn_project_setting.json
	HOST_PROJECT=$(jq -r '.hostProject' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
	HOST_PROJECT_NETWORK=$(jq -r '.clusterNetwork' "${CLUSTER_PROFILE_DIR}/xpn_project_setting.json")
	NETWORK=$(basename ${HOST_PROJECT_NETWORK})
	NETWORK_NAME=projects/${HOST_PROJECT}/global/networks/${NETWORK}
else 
	NETWORK_NAME="$CLUSTER_NAME-network"
fi

export CLUSTER_NAME
export NETWORK_NAME
export STORAGECLASS_LOCATION=${SHARED_DIR}/filestore-sc.yaml
export MANIFEST_LOCATION=${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}

# Create StorageClass
# shared vpc, parameter should add "connect-mode: PRIVATE_SERVICE_ACCESS"
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
  connect-mode: DIRECT_PEERING
  network: $NETWORK_NAME
  reserved-ipv4-cidr: 10.192.0.0/16 # GCE will pick NFS server addresses from this range, should not collide with the defaul OCP networking config
  labels: kubernetes-io-cluster-$CLUSTER_NAME=owned
EOF

if [[ -s "${SHARED_DIR}/xpn.json" ]]
then
	sed -i 's/DIRECT_PEERING/PRIVATE_SERVICE_ACCESS/' $STORAGECLASS_LOCATION 
fi
	
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

oc get sc/filestore-csi -o yaml
