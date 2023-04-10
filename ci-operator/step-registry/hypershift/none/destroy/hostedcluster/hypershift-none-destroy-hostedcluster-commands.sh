#!/bin/bash

set -exuo pipefail
    
hc_name="hc-$(echo -n $PROW_JOB_ID|cut -c-8)"

echo "$(date +%H:%M:%S) Triggering the hosted cluster $hc_name destruction in the namespace hcp-s390x"

hypershift destroy cluster none \
    --name $hc_name \
    --namespace "hcp-s390x" \
    --destroy-cloud-resources \
    --cluster-grace-period 40m

echo "$(date +%H:%M:%S) Successfully destroyed the hosted cluster $hc_name"