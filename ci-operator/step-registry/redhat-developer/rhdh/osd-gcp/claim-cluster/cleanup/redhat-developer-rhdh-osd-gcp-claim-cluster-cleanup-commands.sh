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

# Calculate timestamp from 24 hours ago (1 day)
ONE_DAY_AGO=$(($(date +%s) - 86400))

echo "Looking for clusters that start with 'osd-' and are at least 1 day old"
ocm list clusters | grep -E 'osd-[0-9]+' | while read -r CLUSTER_LINE; do
    CLUSTER_ID=$(echo "$CLUSTER_LINE" | awk '{print $1}')
    CLUSTER_NAME=$(echo "$CLUSTER_LINE" | awk '{print $2}')
    
    # Extract the timestamp from the cluster name (assuming format 'osd-TIMESTAMP')
    CLUSTER_TIMESTAMP=$(echo "$CLUSTER_NAME" | sed -E 's/osd-([0-9]+).*/\1/')
    
    # Check if cluster is at least 1 day old
    if [ -n "$CLUSTER_TIMESTAMP" ] && [ "$CLUSTER_TIMESTAMP" -lt "$ONE_DAY_AGO" ]; then
        echo "Deleting cluster $CLUSTER_ID ($CLUSTER_NAME) - created at $CLUSTER_TIMESTAMP"
        ocm delete "/api/clusters_mgmt/v1/clusters/$CLUSTER_ID"
    else
        echo "Skipping cluster $CLUSTER_NAME - not old enough"
    fi
done

echo "Waiting for clusters to be fully deleted..."
MAX_WAIT_TIME=1800  # 30 minutes in seconds
INTERVAL=180        # 3 minutes in seconds
START_TIME=$(date +%s)

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    
    # Only count clusters that are at least 1 day old
    REMAINING_CLUSTERS=$(ocm list clusters | grep -E 'osd-[0-9]+' | while read -r CLUSTER_LINE; do
        CLUSTER_NAME=$(echo "$CLUSTER_LINE" | awk '{print $2}')
        CLUSTER_TIMESTAMP=$(echo "$CLUSTER_NAME" | sed -E 's/osd-([0-9]+).*/\1/')
        if [ -n "$CLUSTER_TIMESTAMP" ] && [ "$CLUSTER_TIMESTAMP" -lt "$ONE_DAY_AGO" ]; then
            echo "$CLUSTER_LINE"
        fi
    done | wc -l)
    
    if [ "$REMAINING_CLUSTERS" -eq 0 ]; then
        echo "All clusters with prefix 'osd-' that are at least 1 day old have been deleted"
        break
    fi
    
    if [ $ELAPSED_TIME -ge $MAX_WAIT_TIME ]; then
        echo "ERROR: Timeout reached after 30 minutes and $REMAINING_CLUSTERS clusters still exist"
        exit 1
    fi
    echo "Found $REMAINING_CLUSTERS clusters still being deleted. Waiting 3 minutes before next check..."
    sleep $INTERVAL
done
