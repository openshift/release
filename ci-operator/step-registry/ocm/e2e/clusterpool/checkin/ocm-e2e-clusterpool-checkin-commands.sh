#!/bin/bash

log() {
    echo "$(date --iso-8601=seconds)   ${1}"
}

temp=$(mktemp -d -t ocm-XXXXX)
cd $temp || exit 1

cp "$MAKEFILE" ./Makefile

cluster_claims="${SHARED_DIR}/${CLUSTER_CLAIM_FILE}"

if [[ ! -r "$cluster_claims" ]]; then
    log "The cluster claim file does not exist. Not checking in any clusters."
    exit 0
fi

for claim in $(cat "$cluster_claims"); do
    if make clusterpool/checkin CLUSTERPOOL_CLUSTER_CLAIM="$claim"; then
        log "Cluster checked in: $claim"
    else
        log "Error checking in cluster for claim $claim"
    fi
done
