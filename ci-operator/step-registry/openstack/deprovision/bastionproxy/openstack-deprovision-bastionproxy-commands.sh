#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CONFIG_TYPE}" != "byon" ]]; then
    echo "Skipping step due to CONFIG_TYPE not being byon."
    exit 0
fi

export OS_CLIENT_CONFIG_FILE=${SHARED_DIR}/clouds.yaml
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)

>&2 echo "Starting the server cleanup for cluster name '$CLUSTER_NAME'"
openstack server delete "bastionproxy-$CLUSTER_NAME" || >&2 echo "Failed to delete server bastionproxy-$CLUSTER_NAME"
openstack security group delete "$CLUSTER_NAME" || >&2 echo "Failed to delete security group $CLUSTER_NAME"
openstack keypair delete "$CLUSTER_NAME" || >&2 echo "Failed to delete keypair $CLUSTER_NAME"
>&2 echo 'Cleanup done.'
