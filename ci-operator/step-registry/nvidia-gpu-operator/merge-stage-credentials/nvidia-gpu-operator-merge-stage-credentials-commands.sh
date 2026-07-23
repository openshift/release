#!/bin/bash

set -euo pipefail

if [[ "${MERGE_STAGE_REGISTRY_CREDENTIALS}" != "true" ]]; then
    echo "MERGE_STAGE_REGISTRY_CREDENTIALS is not 'true', skipping."
    exit 0
fi

STAGE_REGISTRY_PATH="/var/run/vault/mirror-registry/registry_stage.json"

if [[ ! -f "${STAGE_REGISTRY_PATH}" ]]; then
    echo "Stage registry credentials not found at ${STAGE_REGISTRY_PATH}"
    exit 1
fi

echo "Extracting current cluster pull secret..."
oc extract secret/pull-secret -n openshift-config --confirm --to /tmp

echo "Merging registry.stage.redhat.io credentials..."
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
stage_auth_user=$(jq -r '.user' "${STAGE_REGISTRY_PATH}")
stage_auth_password=$(jq -r '.password' "${STAGE_REGISTRY_PATH}")
stage_registry_auth=$(echo -n "${stage_auth_user}:${stage_auth_password}" | base64 -w 0)

jq --argjson stage "{\"registry.stage.redhat.io\": {\"auth\": \"${stage_registry_auth}\"}}" \
   '.auths |= . + $stage' /tmp/.dockerconfigjson > /tmp/new-dockerconfigjson
$WAS_TRACING && set -x

echo "Updating cluster pull secret..."
oc set data secret/pull-secret -n openshift-config \
    --from-file=.dockerconfigjson=/tmp/new-dockerconfigjson

echo "Waiting for MCP worker pool to start updating..."
COUNTER=0
while [ $COUNTER -lt 120 ]; do
    sleep 20
    COUNTER=$((COUNTER + 20))
    updating=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}')
    echo "MCP Updating=${updating:-unknown} (${COUNTER}s elapsed)"
    if [[ "${updating}" == "True" ]]; then
        echo "MCP update in progress."
        break
    fi
done

echo "Waiting for MCP worker pool to finish updating..."
COUNTER=0
while [ $COUNTER -lt 420 ]; do
    sleep 20
    COUNTER=$((COUNTER + 20))
    updated=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}')
    echo "MCP Updated=${updated:-unknown} (${COUNTER}s elapsed)"
    if [[ "${updated}" == "True" ]]; then
        echo "MCP rollout complete."
        exit 0
    fi
done

echo "MCP rollout timed out after ${COUNTER}s"
oc get mcp worker -o yaml
exit 1
