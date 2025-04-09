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

echo "Waiting for clusters to be fully deleted..."
MAX_WAIT_TIME=1800  # 30 minutes in seconds
INTERVAL=180        # 3 minutes in seconds
START_TIME=$(date +%s)

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    
    if [ $ELAPSED_TIME -ge $MAX_WAIT_TIME ]; then
        echo "Timeout reached after 30 minutes"
        break
    fi

    REMAINING_CLUSTERS=$(ocm list clusters | awk '$2 ~ /^osd-job-/ {print $1}' | wc -l)
    
    if [ "$REMAINING_CLUSTERS" -eq 0 ]; then
        echo "All clusters with prefix 'osd-job-' have been deleted"
        break
    else
        echo "Found $REMAINING_CLUSTERS clusters still being deleted. Waiting 3 minutes before next check..."
        sleep $INTERVAL
    fi
done
