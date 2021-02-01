#!/bin/bash

cp "$MAKEFILE" ./Makefile

claim=""
if [[ -n "$CLUSTER_CLAIM" ]]; then
    claim="$CLUSTER_CLAIM"
elif [[ -f "$CLUSTER_CLAIM_FILE" ]]; then
    claim=$(cat "$CLUSTER_CLAIM_FILE")
fi

if [[ -z "$claim" ]]; then
    echo "No cluster claim found in:"
    echo "  CLUSTER_CLAIM      : $CLUSTER_CLAIM"
    echo "  CLUSTER_CLAIM_FILE : $CLUSTER_CLAIM_FILE"
    exit 1
fi

if [[ -n "$CLUSTER_DATA_FILE" ]]; then
    output="${SHARED_DIR}/${CLUSTER_DATA_FILE}"
else
    output="${SHARED_DIR}/${claim}.json"
fi

make clusterpool/get-cluster-metadata CLUSTERPOOL_CLUSTER_CLAIM="$claim" > $output

if [[ "$?" == 0 ]]; then
    echo "Cluster meta data saved."
    echo "  Cluster Claim : $claim"
    echo "  Output File   : $output"
else
    echo "Error getting cluster metadata for $claim"
    exit 1
fi
