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
	# shellcheck disable=SC1091
	source "${SHARED_DIR}/proxy-conf.sh"
fi

export STORAGECLASS_LOCATION=${SHARED_DIR}/filestore-sc.yaml
export MANIFEST_LOCATION=${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
export CONNECT_MODE="DIRECT_PEERING"

CLUSTER_NAME="$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)"
NETWORK_NAME="${CLUSTER_NAME}-network"

if [[ -s "${SHARED_DIR}/install-config.yaml" ]]; then
  install_config_network="$(yq-go r "${SHARED_DIR}/install-config.yaml" 'platform.gcp.network' 2>/dev/null)"
  if [[ -n "$install_config_network" ]]; then
    NETWORK_NAME="$install_config_network"
    echo "Getting NETWORK_NAME=\"${NETWORK_NAME}\" from install-config"
  fi
fi

# Cross-Project Networking(XPN) extra configure
if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  CONNECT_MODE="PRIVATE_SERVICE_ACCESS"
  SHARED_NETWORK_PROJECT=$(yq-go r "${SHARED_DIR}"/install-config.yaml 'platform.gcp.networkProjectID')
  # Using projects/<project-id>/global/networks/<network-name> is required for filestore CSI driver when the network is not in the current project.
  NETWORK_NAME=projects/${SHARED_NETWORK_PROJECT}/global/networks/${NETWORK_NAME}
  echo "XPN cluster, getting NETWORK_NAME=\"${NETWORK_NAME}\" full path"
fi

# Create StorageClass
# shared vpc, parameter should add "connect-mode: PRIVATE_SERVICE_ACCESS"
echo "Creating a StorageClass"
cat <<EOF >>"$STORAGECLASS_LOCATION"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: filestore-csi
provisioner: filestore.csi.storage.gke.io
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  connect-mode: $CONNECT_MODE
  network: $NETWORK_NAME
  reserved-ipv4-cidr: 10.192.0.0/16 # GCE will pick NFS server addresses from this range, should not collide with the defaul OCP networking config
  labels: kubernetes-io-cluster-$CLUSTER_NAME=owned
EOF
	
echo "Using StorageClass file ${STORAGECLASS_LOCATION}"
cat "${STORAGECLASS_LOCATION}"

oc create -f "${STORAGECLASS_LOCATION}"
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
cat <<EOF >>"$MANIFEST_LOCATION"
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
cat "${MANIFEST_LOCATION}"
