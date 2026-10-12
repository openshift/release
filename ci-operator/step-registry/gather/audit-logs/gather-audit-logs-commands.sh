#!/bin/bash

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering audit logs."
	exit 0
fi

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

# Allow a job to override the must-gather image, this is needed for
# disconnected environments prior to 4.8.
if test -f "${SHARED_DIR}/must-gather-image.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/must-gather-image.sh"
else
	MUST_GATHER_IMAGE=${MUST_GATHER_IMAGE:-""}
fi

mkdir -p "${ARTIFACT_DIR}/audit-logs"
VOLUME_PERCENTAGE_FLAG=""
if oc adm must-gather --help 2>&1 | grep -q -- '--volume-percentage'; then
   VOLUME_PERCENTAGE_FLAG="--volume-percentage=100"
fi

oc adm must-gather $MUST_GATHER_IMAGE $VOLUME_PERCENTAGE_FLAG --dest-dir="${ARTIFACT_DIR}/audit-logs" -- /usr/bin/gather_audit_logs
tar -czC "${ARTIFACT_DIR}/audit-logs" -f "${ARTIFACT_DIR}/audit-logs.tar.gz" .
rm -rf "${ARTIFACT_DIR}/audit-logs"
