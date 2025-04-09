#!/bin/bash
set -e

export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

curl -Lo ocm https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64

export CLIENT_ID CLIENT_SECRET

CLIENT_ID=$(cat /tmp/osdsecrets/OSD_CLIENT_ID)
CLIENT_SECRET=$(cat /tmp/osdsecrets/OSD_CLIENT_SECRET)

ocm login --client-id=$CLIENT_ID --client-secret=$CLIENT_SECRET

echo "Logged in as $(ocm whoami | jq -rc '.username')"

echo "Looking for clusters that start with 'osd-job-'"
ocm list clusters | awk '$2 ~ /^osd-job-/ {print $1}' | while read -r CLUSTER_ID; do
    echo "Deleting cluster $CLUSTER_ID"
    ocm delete "/api/clusters_mgmt/v1/clusters/$CLUSTER_ID"
done
