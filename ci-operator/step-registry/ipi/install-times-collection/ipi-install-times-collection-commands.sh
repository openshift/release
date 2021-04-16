#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Updating Cluster Infra ConfigMap with the start and end times."
START_TIME=$(cat "$SHARED_DIR/CLUSTER_INSTALL_START_TIME")
END_TIME=$(cat "$SHARED_DIR/CLUSTER_INSTALL_END_TIME")
CLUSTER_INSTALL_PATCH=$(echo '{"data":{"startTime":"'$START_TIME'","endTime":"'$END_TIME'"}}')
oc patch configmap openshift-install -n openshift-config -p $CLUSTER_INSTALL_PATCH
