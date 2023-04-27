#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

set -x

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
