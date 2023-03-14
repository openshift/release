#!/bin/bash

set -exuo pipefail
    
hc_name="z-hc-$(echo -n $PROW_JOB_ID|cut -c-8)"

echo "$(date) Triggering the hosted cluster $hc_name destruction in the namespace clusters_$hc_name"

/usr/bin/hypershift destroy cluster none \
    --name $hc_name \
    --namespace "clusters-$hc_name" \
    --destroy-cloud-resources \
    --cluster-grace-period 40m

echo "$(date) Successfully destroyed the hosted cluster $hc_name"