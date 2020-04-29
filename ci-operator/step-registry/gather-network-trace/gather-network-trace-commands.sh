#!/bin/bash
#set -x

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering extra artifacts."
	exit 0
fi

echo "Gathering network ovn artifacts ..."

TARGET_DIR=${ARTIFACT_DIR}/ovn-trace
mkdir -p ${TARGET_DIR}

oc adm must-gather --dest-dir="${TARGET_DIR}" -- /usr/bin/gather_network_ovn_trace
tar -czC "${TARGET_DIR}" -f "${ARTIFACT_DIR}/ovn-trace.tar.gz" .
rm -rf "${TARGET_DIR}"
