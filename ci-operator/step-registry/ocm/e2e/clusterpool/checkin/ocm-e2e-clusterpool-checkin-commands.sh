#!/bin/bash

temp=$(mktemp -d -t ocm-XXXXX)
cd $temp || exit 1

cp "$MAKEFILE" ./Makefile

cluster_claims="${SHARED_DIR}/${CLUSTER_CLAIM_FILE}"

if [[ ! -r "$cluster_claims" ]]; then
    echo "The cluster claim file does not exist. Not checking in any clusters."
    exit 0
fi

for claim in $(cat "$cluster_claims"); do
    make clusterpool/checkin CLUSTERPOOL_CLUSTER_CLAIM="$claim"

    if [[ "$?" == 0 ]]; then
        echo "Cluster checked in: $claim"
    else
        echo "Error checking in cluster for claim $claim"
    fi
done
