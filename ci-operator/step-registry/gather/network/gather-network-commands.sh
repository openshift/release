#!/bin/bash
#set -x

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering extra artifacts."
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

echo "Gathering network artifacts ..."

mkdir -p ${ARTIFACT_DIR}/network

timeout 30m oc adm must-gather --dest-dir="${ARTIFACT_DIR}/network" -- /usr/bin/gather_network_logs
tar -czC "${ARTIFACT_DIR}/network" -f "${ARTIFACT_DIR}/network.tar.gz" .
rm -rf "${ARTIFACT_DIR}/network"
