#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# camgi is a tool that creates an html document for investigating an OpenShift cluster
# see https://github.com/elmiko/camgi.rs for more information
function installCamgi() {
    CAMGI_VERSION="0.8.1"
    pushd /tmp
    curl -L -o camgi.tar https://github.com/elmiko/camgi.rs/releases/download/v"$CAMGI_VERSION"/camgi-"$CAMGI_VERSION"-linux-x86_64.tar
    tar xvf camgi.tar
    sha256sum -c camgi.sha256
    popd
}

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in calling kubevirt-must-gather."
	exit 0
fi

KUBEVIRT_MUST_GATHER_ARTIFACT_DIR=${ARTIFACT_DIR}/kubevirt-must-gather
MUST_GATHER_TIMEOUT=${MUST_GATHER_TIMEOUT:-"15m"}

echo "Running kubevirt-must-gather..."
mkdir -p "${KUBEVIRT_MUST_GATHER_ARTIFACT_DIR}"

oc adm must-gather "$KUBEVIRT_MUST_GATHER_IMAGE" \
    --insecure-skip-tls-verify \
    --timeout="$MUST_GATHER_TIMEOUT" \
    --dest-dir "${KUBEVIRT_MUST_GATHER_ARTIFACT_DIR}" > "${KUBEVIRT_MUST_GATHER_ARTIFACT_DIR}/must-gather.log"

[ -f "${KUBEVIRT_MUST_GATHER_ARTIFACT_DIR}/event-filter.html" ] && cp "${KUBEVIRT_MUST_GATHER_ARTIFACT_DIR}/event-filter.html" "${ARTIFACT_DIR}/event-filter.html"
installCamgi
/tmp/camgi "${KUBEVIRT_MUST_GATHER_ARTIFACT_DIR}" > "${KUBEVIRT_MUST_GATHER_ARTIFACT_DIR}/camgi.html"

[ -f "${KUBEVIRT_MUST_GATHER_ARTIFACT_DIR}/camgi.html" ] && cp "${KUBEVIRT_MUST_GATHER_ARTIFACT_DIR}/camgi.html" "${ARTIFACT_DIR}/camgi.html"
tar -czC "${KUBEVIRT_MUST_GATHER_ARTIFACT_DIR}" -f "${ARTIFACT_DIR}/kubevirt-must-gather.tar.gz" .
rm -rf "${KUBEVIRT_MUST_GATHER_ARTIFACT_DIR}"