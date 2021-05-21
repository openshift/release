#!/bin/bash

temp=$(mktemp -d -t ocm-XXXXX)
cd $temp || exit 1

cp "$MAKEFILE" ./Makefile

pools=""
if [[ -n "$CLUSTERPOOL_LIST" ]] ; then
    pools=$(echo "$CLUSTERPOOL_LIST" | tr "," "\n")
elif [[ -f "${SHARED_DIR}/${CLUSTERPOOL_LIST_FILE}" ]] ; then
    pools=$(cat "${SHARED_DIR}/${CLUSTERPOOL_LIST_FILE}")
fi

if [[ -z "$pools" ]]; then
    echo "No pools specified by CLUSTERPOOL_LIST or CLUSTERPOOL_LIST_FILE"
    exit 1
fi

suffix=$(cat /dev/urandom | tr -dc "a-z0-9" | head -c 5 )

# Checkout hub clusters
for ((i=1;i<=CLUSTERPOOL_HUB_COUNT;i++)); do
    cluster_claim=""
    for pool in $pools; do
        tmp_claim="hub-$i-$suffix"
        make clusterpool/checkout \
            CLUSTERPOOL_NAME=$pool \
            CLUSTERPOOL_CLUSTER_CLAIM=$tmp_claim
    
        if [[ "$?" == 0 ]]; then
            cluster_claim="$tmp_claim"
            break
        fi
    done
    
    if [[ -z "$cluster_claim" ]]; then
        echo "No cluster was checked out for hub $i. Tried these cluster pools:"
        echo "$pools"
        exit 1
    fi
    
    echo "$cluster_claim" >> "${SHARED_DIR}/${CLUSTER_CLAIM_FILE}"
done


# Checkout managed clusters
for ((i=1;i<=CLUSTERPOOL_MANAGED_COUNT;i++)); do
    cluster_claim=""
    for pool in $pools; do
        tmp_claim="managed-$i-$suffix"
        make clusterpool/checkout \
            CLUSTERPOOL_NAME=$pool \
            CLUSTERPOOL_CLUSTER_CLAIM=$tmp_claim
    
        if [[ "$?" == 0 ]]; then
            cluster_claim="$tmp_claim"
            break
        fi
    done
    
    if [[ -z "$cluster_claim" ]]; then
        echo "No cluster was checked out for managed $i. Tried these cluster pools:"
        echo "$pools"
        exit 1
    fi
    
    echo "$cluster_claim" >> "${SHARED_DIR}/${CLUSTER_CLAIM_FILE}"
done


echo "Cluster claims:"
cat "${SHARED_DIR}/${CLUSTER_CLAIM_FILE}"
