#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig defined, must-gather cannot be run."
	exit 0
fi 

echo "Running must-gather..."
mkdir -p ${ARTIFACT_DIR}/must-gather
oc --insecure-skip-tls-verify adm must-gather $MUST_GATHER_IMAGE --timeout=$MUST_GATHER_TIMEOUT --dest-dir ${ARTIFACT_DIR}/must-gather
tar -czC "${ARTIFACT_DIR}/must-gather" -f "${ARTIFACT_DIR}/must-gather.tar" .
