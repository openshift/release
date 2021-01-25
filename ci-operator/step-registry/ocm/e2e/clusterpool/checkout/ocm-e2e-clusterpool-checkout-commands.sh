#!/bin/bash

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

cluster_claim=""
for pool in $pools; do
    tmp_claim="$pool-$suffix"
    make clusterpool/checkout \
        CLUSTERPOOL_NAME=$pool \
        CLUSTERPOOL_CLUSTER_CLAIM=$tmp_claim

    if [[ "$?" == 0 ]]; then
        cluster_claim="$tmp_claim"
        break
    fi
done

if [[ -z "$cluster_claim" ]]; then
    echo "No cluster was checked out. Tried these cluster pools:"
    echo "$pools"
    exit 1
fi

echo "$cluster_claim" > "${SHARED_DIR}/${CLUSTER_CLAIM_FILE}"

echo "Cluster claim: $cluster_claim"
