#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

set -x

echo "Waiting for the ClusterCSIDriver $CLUSTERCSIDRIVER to get created"
while true; do
    oc get clustercsidriver $CLUSTERCSIDRIVER -o yaml && break
    sleep 5
done

ARGS=""
for CND in $TRUECONDITIONS; do
    ARGS="$ARGS --for=condition=$CND"
done

echo "Waiting for the ClusterCSIDriver $CLUSTERCSIDRIVER conditions $ARGS"
if ! oc wait --timeout=300s $ARGS clustercsidriver $CLUSTERCSIDRIVER; then
    # Wait failed
    echo "Wait failed. Current ClusterCISDriver:"
    oc get clustercsidriver $CLUSTERCSIDRIVER -o yaml
    exit 1
fi
