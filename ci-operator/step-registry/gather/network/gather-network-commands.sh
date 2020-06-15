#!/bin/bash
#set -x

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering extra artifacts."
	exit 0
fi

echo "Gathering network ovn artifacts ..."

mkdir -p ${ARTIFACT_DIR}/network-ovn

oc adm must-gather --dest-dir="${ARTIFACT_DIR}/network-ovn" -- /usr/bin/gather_network_logs
tar -czC "${ARTIFACT_DIR}/network-ovn" -f "${ARTIFACT_DIR}/network-ovn.tar.gz" .
rm -rf "${ARTIFACT_DIR}/network-ovn"
