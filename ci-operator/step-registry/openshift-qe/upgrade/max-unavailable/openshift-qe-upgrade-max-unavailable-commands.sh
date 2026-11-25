#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

MAX_UNAVAILABLE_WORKER=${MAX_UNAVAILABLE_WORKER:=""}

# _wait_for <resource> <resource_name> <desired_state> <timeout in minutes>
_wait_for(){
    echo "Waiting for $2 $1 to be $3 in $4 Minutes"
    oc wait --for=condition=$3 --timeout=$4m $1 $2
}

if [[ $MAX_UNAVAILABLE_WORKER != "" ]]; then
    echo "MCP updating.."
    echo "Setting maxUnavailable for worker mcp"
    START_TIME=$(date +%s)
    oc patch mcp worker --type='merge' --patch '{ "spec": { "maxUnavailable": '$MAX_UNAVAILABLE_WORKER' } }'

    # _wait_for <resource> <resource_name> <desired_state> <timeout in minutes> 
    WORKERS=$(oc get nodes | grep -ic worker)
    _wait_for mcp worker Updated=True $(($WORKERS*5))
    _wait_for mcp worker Updating=False 30
    _wait_for mcp worker Degraded=False 10

    STOP_TIME=$(date +%s)
    DURATION=$((STOP_TIME - START_TIME))
    oc get mcp worker -o jsonpath='{.spec.maxUnavailable}'
    echo "Worker mcp is updated. Duration is ${DURATION}s."
else
    echo "MAX_UNAVAILABLE_WORKER is not set, skip this step."
fi