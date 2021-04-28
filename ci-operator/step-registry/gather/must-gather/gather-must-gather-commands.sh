#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in calling must-gather."
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

echo "Running must-gather..."
mkdir -p ${ARTIFACT_DIR}/must-gather
oc --insecure-skip-tls-verify adm must-gather --dest-dir ${ARTIFACT_DIR}/must-gather > ${ARTIFACT_DIR}/must-gather/must-gather.log
[ -f "${ARTIFACT_DIR}/must-gather/event-filter.html" ] && cp "${ARTIFACT_DIR}/must-gather/event-filter.html" "${ARTIFACT_DIR}/event-filter.html"
tar -czC "${ARTIFACT_DIR}/must-gather" -f "${ARTIFACT_DIR}/must-gather.tar.gz" .
rm -rf "${ARTIFACT_DIR}"/must-gather
