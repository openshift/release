#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

control_plane_node_count=$(oc get node --no-headers | grep master | wc -l)
compute_node_count=$(oc get node --no-headers | grep worker | wc -l)

echo "Nodes:"
oc get node --no-headers -owide

if [[ "${control_plane_node_count}" != "${EXPECTED_CONTROL_PLANE_NODE_COUNT}" ]]; then
    echo "ERROR: control plane nodes: ${control_plane_node_count}, expect ${EXPECTED_CONTROL_PLANE_NODE_COUNT}, exit now"
    exit 1
fi

if [[ "${compute_node_count}" != "${EXPECTED_COMPUTE_NODE_COUNT}" ]]; then
    echo "ERROR: compute nodes: ${compute_node_count}, expect ${EXPECTED_COMPUTE_NODE_COUNT}, exit now"
    exit 1
fi
