#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in calling must-gather."
	exit 0
fi

echo "Running must-gather..."
mkdir -p "${ARTIFACT_DIR}/must-gather"
oc --insecure-skip-tls-verify adm must-gather --dest-dir "${ARTIFACT_DIR}/must-gather" > "${ARTIFACT_DIR}/must-gather/must-gather.log"
tar -czC "${ARTIFACT_DIR}/must-gather" -f "${ARTIFACT_DIR}/must-gather.tar.gz" .
rm -rf "${ARTIFACT_DIR}"/must-gather
