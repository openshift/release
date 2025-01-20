#!/bin/bash
set -e

export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

curl -Lo ocm https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-info.id")

CLIENT_ID=$(cat /tmp/osdsecrets/OSD_CLIENT_ID)
CLIENT_SECRET=$(cat /tmp/osdsecrets/OSD_CLIENT_SECRET)
ocm login --client-id=$CLIENT_ID --client-secret=$CLIENT_SECRET

ocm describe cluster $CLUSTER_ID

ocm delete /api/clusters_mgmt/v1/clusters/$CLUSTER_ID
