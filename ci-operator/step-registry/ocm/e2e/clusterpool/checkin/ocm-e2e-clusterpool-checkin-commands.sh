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
else
    echo "Checking in cluster claim: $claim"
fi

make clusterpool/checkin CLUSTERPOOL_CLUSTER_CLAIM="$claim"

if [[ "$?" == 0 ]]; then
    echo "Cluster checked in."
    echo "  Cluster Claim : $claim"
else
    echo "Error checking in cluster for claim $claim"
    exit 1
fi
