#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Handle proxy for disconnected environments
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Build hydrophone (latest version)
echo "Building hydrophone..."
export GOFLAGS=""
go install sigs.k8s.io/hydrophone@latest

# Get Kubernetes version from cluster
K8S_VERSION=$(oc version -ojson | jq -r '.serverVersion.gitVersion | sub("[\\+].*"; "")')
echo "Detected Kubernetes version: ${K8S_VERSION}"

# Count unschedulable nodes (masters, control-plane, infra)
UNSCHEDULABLE_NODE_COUNT=$(oc get nodes -ojson | jq --raw-output '
  [ .items[].metadata | select (
    .labels."node-role.kubernetes.io/master" == "" or
    .labels."node-role.kubernetes.io/control-plane" == "" or
    .labels."node-role.kubernetes.io/infra" == ""
  ) | .name ] | length')
echo "Unschedulable node count: ${UNSCHEDULABLE_NODE_COUNT}"

# Allow permissive SCCs for conformance tests
oc adm policy add-scc-to-group privileged system:authenticated system:serviceaccounts
oc adm policy add-scc-to-group anyuid system:authenticated system:serviceaccounts

# Run conformance tests
echo "Starting CNCF Kubernetes conformance tests..."
hydrophone \
  --conformance \
  --conformance-image "registry.k8s.io/conformance:${K8S_VERSION}" \
  --extra-args="--allowed-not-ready-nodes=${UNSCHEDULABLE_NODE_COUNT}" \
  --output-dir "${ARTIFACT_DIR}"
