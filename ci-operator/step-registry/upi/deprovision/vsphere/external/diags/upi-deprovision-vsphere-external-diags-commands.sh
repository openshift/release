#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in calling oc adm inspect."
	exit 0
fi

NAMESPACES="vsphere-cloud-controller-manager"

echo "Running oc adm inspect..."
mkdir -p ${ARTIFACT_DIR}/inspect
oc --insecure-skip-tls-verify adm inspect namespace ${NAMESPACES} --dest-dir ${ARTIFACT_DIR}/inspect > ${ARTIFACT_DIR}/inpsect/inspect.log
tar -czC "${ARTIFACT_DIR}/inspect" -f "${ARTIFACT_DIR}/inspect.tar.gz" .
rm -rf "${ARTIFACT_DIR}"/inspect
