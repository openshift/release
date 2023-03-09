#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MUST_GATHER_DIR="${ARTIFACT_DIR}/must-gather"

mkdir -p "${MUST_GATHER_DIR}"
oc --kubeconfig="${SHARED_DIR}/kubeconfig" adm must-gather --dest-dir="${MUST_GATHER_DIR}"
tar -czC "${MUST_GATHER_DIR}" -f "${ARTIFACT_DIR}/must-gather.tar.gz" .
rm -rf "${MUST_GATHER_DIR}"
