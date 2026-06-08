#!/bin/bash

set -o nounset
set -o pipefail

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

echo "Updating openshift-install ConfigMap with the start and end times."
START_TIME=$(cat "$SHARED_DIR/CLUSTER_INSTALL_START_TIME")
END_TIME=$(cat "$SHARED_DIR/CLUSTER_INSTALL_END_TIME")
if ! oc patch configmap openshift-install -n openshift-config -p '{"data":{"startTime":"'"$START_TIME"'","endTime":"'"$END_TIME"'"}}'
then
    oc create configmap openshift-install -n openshift-config --from-literal=startTime="$START_TIME" --from-literal=endTime="$END_TIME"
fi
