#!/bin/bash

temp=$(mktemp -d -t ocm-XXXXX)
cd "$temp" || exit 1

cp "$MAKEFILE" ./Makefile

OC_CLUSTER_TOKEN=$(cat "/etc/$CLUSTERPOOL_HOST_PROW_KUBE_SECRET/token")
export OC_CLUSTER_TOKEN
export OC_CLUSTER_URL="$CLUSTERPOOL_HOST_API"

# claims are in the form hub-1-abcde
while read -r claim; do 
    # strip off the -abcde suffix
    cluster=$( sed -e "s/-[[:alnum:]]\+$//" <<<"$claim" )
    kc_output="${SHARED_DIR}/${cluster}.kc"
    json_output="${SHARED_DIR}/${cluster}.json"

    # Get cluster claim namespace
    oc_command="get clusterclaim.hive $claim -o jsonpath='{.spec.namespace}'"
    if ! make -s oc/command OC_COMMAND="$oc_command" > namespace; then
        echo "Error getting hive namespace for cluster claim $claim"
        exit 1
    fi
    ns=$(cat namespace)

    # Get cluster claim kubeconfig secret name
    oc_command="get -n $ns clusterdeployment $ns -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}'"
    if ! make -s oc/command OC_COMMAND="$oc_command" > secret_name; then
        echo "Error getting kubeconfig secret name for cluster claim $claim"
        exit 1
    fi
    kc=$(cat secret_name)

    # Get the cluster claim kubeconfig file
    oc_command="get -n $ns secret $kc -o jsonpath='{.data.kubeconfig}'"
    if make -s oc/command OC_COMMAND="$oc_command" > >(base64 --decode > "$kc_output"); then
        echo "Cluster kubeconfig for $claim saved to $kc_output"
    else
        echo "Error getting cluster kubeconfig for $claim"
        exit 1
    fi

    # Get the metadata file for the cluster
    if make clusterpool/get-cluster-metadata \
        CLUSTERPOOL_CLUSTER_CLAIM="$claim" \
        CLUSTERPOOL_METADATA_FILE="$json_output" > /dev/null ; then
        echo "Cluster meta data for $claim saved to $json_output"
    else
        echo "Error getting cluster metadata for $claim"
        exit 1
    fi
    
done < "${SHARED_DIR}/${CLUSTER_CLAIM_FILE}"
