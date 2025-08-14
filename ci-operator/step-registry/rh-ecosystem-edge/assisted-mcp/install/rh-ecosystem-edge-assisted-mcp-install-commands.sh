#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo $ASSISTED_MCP_IMG
IMAGE=$(echo $ASSISTED_MCP_IMG | cut -d ":" -f1)
TAG=$(echo $ASSISTED_MCP_IMG | cut -d ":" -f2)

cd assisted-service-mcp
oc create namespace $NAMESPACE || true
oc process -p IMAGE=$IMAGE -p IMAGE_TAG=$TAG -f template.yaml --local | oc apply -n $NAMESPACE -f -

sleep 5
POD_NAME=$(oc get pods | tr -s ' ' | cut -d ' ' -f1| grep assisted-service-mcp)
oc wait --for=condition=Ready pod/$POD_NAME --timeout=300s