#!/bin/bash
set -euo pipefail

# Source proxy config for cluster API access through the baremetalds squid proxy.
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Extracting current cluster pull secret..."
oc get secret pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/existing-pull-secret.json

# Disable tracing around secret handling to avoid credentials appearing in logs.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

echo "Merging cluster profile pull secret into cluster global pull secret..."
jq -s '.[0] * .[1]' \
  /tmp/existing-pull-secret.json \
  "${CLUSTER_PROFILE_DIR}/pull-secret" > /tmp/merged-pull-secret.json

$WAS_TRACING && set -x

echo "Patching openshift-config/pull-secret..."
oc set data secret/pull-secret -n openshift-config \
  --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json

echo "Waiting for MachineConfigPools to roll out updated pull secret..."
oc wait mcp/master --for=condition=Updating=True --timeout=3m || true
oc wait mcp/worker --for=condition=Updating=True --timeout=3m || true

oc wait mcp/master --for=condition=Updated=True --timeout=15m
oc wait mcp/worker --for=condition=Updated=True --timeout=15m

echo "Pull secret successfully updated on all nodes."
