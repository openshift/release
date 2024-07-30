#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

HASH="$(echo -n $PROW_JOB_ID|sha256sum)"
CLUSTER_NAME=${HASH:0:20}
INFRA_ID=${HASH:20:5}

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"

# This was taken from other Hypershift jobs, this is how the hosted cluster
# is named in CI.
HASH="$(echo -n $PROW_JOB_ID|sha256sum)"
CLUSTER_NAME=${HASH:0:20}

echo "Get the Hypershift Hosted Cluster network ID"
NETWORK_ID=$(openstack network show "k8s-clusterapi-cluster-clusters-$CLUSTER_NAME-$INFRA_ID" -f value -c id)
if [ -z "$NETWORK_ID" ]; then
  echo "Failed to get the Hypershift Hosted Cluster network ID"
  exit 1
fi

echo "Creating the Ingress port for the Hypershift Hosted Cluster"
INGRESS_PORT_ID=$(openstack port create --network "$NETWORK_ID" --fixed-ip ip-address="$HCP_INGRESS_IP" --description "Created by CI for hypershift/e2e cluster $CLUSTER_NAME" "$CLUSTER_NAME-ingress" -f value -c id)
if [ -z "$INGRESS_PORT_ID" ]; then
  echo "Failed to create the Ingress port for the Hypershift Hosted Cluster"
  exit 1
fi
echo "$INGRESS_PORT_ID" > ${SHARED_DIR}/HCP_INGRESS_PORT_ID

echo "Creating the Ingress floating IP for the Hypershift Hosted Cluster"
INGRESS_FIP=$(openstack floating ip create "$OPENSTACK_EXTERNAL_NETWORK" --port "$INGRESS_PORT_ID" --description "Created by CI for hypershift/e2e cluster $CLUSTER_NAME" -f value -c floating_ip_address)
if [ -z "$INGRESS_FIP" ]; then
  echo "Failed to create the Ingress floating IP for the Hypershift Hosted Cluster"
  exit 1
fi
echo "$INGRESS_FIP" > ${SHARED_DIR}/HCP_INGRESS_FIP
echo "$INGRESS_FIP" >> ${SHARED_DIR}/DELETE_FIPS

echo "Done"