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