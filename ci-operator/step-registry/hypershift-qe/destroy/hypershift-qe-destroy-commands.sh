#!/bin/bash

set -euo pipefail

NAMESPACE="clusters"

gclusters=$(oc get hostedcluster -n "$NAMESPACE" -ojsonpath='{.items[*].metadata.name}')
gclusters_arr=("$gclusters")
for cluster_item in "${gclusters_arr[@]}"
do
    echo "begin to destroy cluster ${cluster_item}"
    platform=$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')
    if [ "$platform" == 'Azure' ]; then
        location=$(oc get node -ojsonpath='{.items[].metadata.labels.topology\.kubernetes\.io/region}')
        hypershift destroy cluster azure \
            --aws-creds "$SHARED_DIR/azurecredentials" \
            --namespace "$NAMESPACE" \
            --name "$cluster_item" \
            --location "$location"
    elif [ "$platform" == "AWS" ]; then
        region=$(oc get node -ojsonpath='{.items[].metadata.labels.topology\.kubernetes\.io/region}')
        hypershift destroy cluster aws \
            --aws-creds "$SHARED_DIR/awscredentials" \
            --namespace "$NAMESPACE" \
            --name "$cluster_item" \
            --region "$region"
    fi
done