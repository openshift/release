#!/bin/bash

set -o nounset
set -o pipefail

echo "Updating openshift-install ConfigMap with the start and end times."
START_TIME=$(cat "$SHARED_DIR/CLUSTER_INSTALL_START_TIME")
END_TIME=$(cat "$SHARED_DIR/CLUSTER_INSTALL_END_TIME")
if ! oc patch configmap openshift-install -n openshift-config -p '{"data":{"startTime":"'"$START_TIME"'","endTime":"'"$END_TIME"'"}}'
then
    oc create configmap openshift-install -n openshift-config --from-literal=startTime="$START_TIME" --from-literal=endTime="$END_TIME"
fi
