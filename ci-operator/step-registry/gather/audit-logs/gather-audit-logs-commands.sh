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
	# shellcheck source=/dev/null
	source "${SHARED_DIR}/proxy-conf.sh"
fi

mkdir -p "${ARTIFACT_DIR}/audit-logs"
oc adm must-gather --dest-dir="${ARTIFACT_DIR}/audit-logs" -- /usr/bin/gather_audit_logs
tar -czC "${ARTIFACT_DIR}/audit-logs" -f "${ARTIFACT_DIR}/audit-logs.tar.gz" .
rm -rf "${ARTIFACT_DIR}/audit-logs"
