#!/bin/bash

cp "$MAKEFILE" ./Makefile

for claim in $(cat "${SHARED_DIR}/${CLUSTER_CLAIM_FILE}"); do
    make clusterpool/checkin CLUSTERPOOL_CLUSTER_CLAIM="$claim"

    if [[ "$?" == 0 ]]; then
        echo "Cluster checked in: $claim"
    else
        echo "Error checking in cluster for claim $claim"
    fi
done
