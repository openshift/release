#!/bin/bash

set -ex
export KUBECONFIG=${SHARED_DIR}/abi-kubeconfig

echo "$(date) Checking the SNO status" 
oc wait no --all --for=condition=Ready=true --timeout=30m
echo "$(date) SNO cluster is ready"

echo "$(date) Verifying the cluster operators status"
oc wait --all=true co --for=condition=Available=True --timeout=30m
echo "$(date) All cluster operators are ready"
