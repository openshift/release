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
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

CCM_MUST_GATHER_IMAGE=quay.io/elmiko/must-gather:cccmo

echo "Running must-gather-ccm..."
mkdir -p ${ARTIFACT_DIR}/must-gather-ccm
oc --insecure-skip-tls-verify adm must-gather --image ${CCM_MUST_GATHER_IMAGE} --dest-dir ${ARTIFACT_DIR}/must-gather-ccm > ${ARTIFACT_DIR}/must-gather-ccm/must-gather.log
tar -czC "${ARTIFACT_DIR}/must-gather-ccm" -f "${ARTIFACT_DIR}/must-gather-ccm.tar.gz" .
rm -rf "${ARTIFACT_DIR}"/must-gather-ccm
