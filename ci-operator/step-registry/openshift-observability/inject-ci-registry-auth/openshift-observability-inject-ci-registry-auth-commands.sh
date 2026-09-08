#!/bin/bash

set -euo pipefail

echo "Generating CI build cluster registry credentials..."
KUBECONFIG="" oc registry login --to=/tmp/ci-registry-auth.json

echo "Extracting current cluster pull secret..."
oc extract secret/pull-secret -n openshift-config --confirm --to=/tmp

echo "Merging CI registry credentials into cluster pull secret..."
jq -s '.[0] * .[1]' /tmp/.dockerconfigjson /tmp/ci-registry-auth.json > /tmp/merged-pull-secret.json

echo "Updating cluster pull secret..."
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json

echo "Waiting for MachineConfigPool worker to begin updating..."
sleep 10

echo "Waiting for MachineConfigPool worker to finish rolling out..."
oc wait mcp/worker --for=condition=Updated=True --timeout=10m || true

echo "CI registry credentials injected successfully."
