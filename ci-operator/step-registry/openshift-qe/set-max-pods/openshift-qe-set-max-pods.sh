#!/bin/bash

set -euo pipefail

MAX_PODS=500 # Set the desired maxPods value

NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')

for NODE in $NODES; do
  oc patch node "$NODE" --type=merge -p "{\"spec\":{\"podCidr\":{\"maxPods\": $MAX_PODS}}}"
done
