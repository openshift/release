#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Even the cluster is shown ready on ocm side, and the cluster operators are available, some of the cluster operators are
# still progressing. The ocp e2e test scenarios requires PROGRESSING=False for each cluster operator.
echo "Wait for cluster operators' progressing ready..."
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=30m
echo "All cluster operators are done progressing."
