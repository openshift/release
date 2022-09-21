#!/bin/bash

NAMESPACE="clusters"

gclusters=$(oc get hostedcluster -n "$NAMESPACE" -ojsonpath='{.items[*].metadata.name}')
gclusters_arr=(${gclusters})
for cluster_item in ${gclusters_arr[@]}
do
    echo "begin to destroy cluster ${cluster_item}"
    platform=$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')
    bash "hack/export-credentials.sh" "$platform"
    if [ "$platform" == 'Azure' ]; then
        location=$(oc get node -ojsonpath='{.items[].metadata.labels.topology\.kubernetes\.io/region}')
        hypershift destroy cluster azure \
            --aws-creds config/azurecredentials \
            --namespace "$NAMESPACE" \
            --name "$cluster_item" \
            --location "$location"
    elif [ "$platform" == "AWS" ]; then
        REGION=$(oc get node -ojsonpath='{.items[].metadata.labels.topology\.kubernetes\.io/region}')
        hypershift destroy cluster aws \
            --aws-creds config/awscredentials \
            --namespace "$NAMESPACE" \
            --name "$cluster_item" \
            --region "$REGION"
    fi
done