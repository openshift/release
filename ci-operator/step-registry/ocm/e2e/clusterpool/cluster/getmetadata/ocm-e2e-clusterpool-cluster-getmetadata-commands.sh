#!/bin/bash

temp=$(mktemp -d -t ocm-XXXXX)
cd $temp || exit 1

cp "$MAKEFILE" ./Makefile

# claims are in the form hub-1-abcde
for claim in $(cat ${SHARED_DIR}/${CLUSTER_CLAIM_FILE}); do
    # strip off the -abcde suffix
    cluster=$( sed -e "s/-[[:alnum:]]\+$//" <<<$claim )
    output="${SHARED_DIR}/${cluster}.json"

    make clusterpool/get-cluster-metadata \
        CLUSTERPOOL_CLUSTER_CLAIM="$claim" \
        CLUSTERPOOL_METADATA_FILE="$output"

    if [[ "$?" == 0 ]]; then
        echo "Cluster meta data for $claim saved to $output"
    else
        echo "Error getting cluster metadata for $claim"
        exit 1
    fi
done
