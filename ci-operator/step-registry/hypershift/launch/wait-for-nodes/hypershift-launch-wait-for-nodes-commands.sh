#!/bin/bash
set -euo pipefail

echo "$(date) Waiting for all nodes to join the cluster"
while true; do
  [[ $(oc get nodes --output go-template='{{ len .items }}') -eq "${WAIT_FOR_NODES_COUNT}" ]] && break
  sleep 5
done

echo "$(date) Waiting for all nodes to become ready"
oc wait nodes --all --for condition=Ready --timeout 24h

echo "$(date) All nodes are ready"
