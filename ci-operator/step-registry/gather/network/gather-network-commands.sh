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

mkdir -p "${ARTIFACT_DIR}/links"
oc --request-timeout=5s get nodes -o jsonpath --template '{range .items[*]}{.metadata.name}{"\n"}{end}' >/tmp/nodes
while IFS= read -r NAME; do
	echo "Gathering /host/etc/systemd/network/*.link from ${NAME}..."
	oc -v=6 --request-timeout=60s debug "node/${NAME}" -- sh -c 'ls -l /host/etc/systemd && ls -l /host/etc/systemd/network && head -n1000 /host/etc/systemd/network/*.link' > "${ARTIFACT_DIR}/links/${NAME}.txt" || true
done </tmp/nodes

mkdir -p ${ARTIFACT_DIR}/network

echo "Gathering must-gather network logs..."
oc adm must-gather --dest-dir="${ARTIFACT_DIR}/network" -- /usr/bin/gather_network_logs
tar -czC "${ARTIFACT_DIR}/network" -f "${ARTIFACT_DIR}/network.tar.gz" .
rm -rf "${ARTIFACT_DIR}/network"
