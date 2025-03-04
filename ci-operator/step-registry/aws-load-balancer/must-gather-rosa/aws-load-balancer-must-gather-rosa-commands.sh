#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MUST_GATHER_DIR="${ARTIFACT_DIR}/must-gather"

mkdir -p "${MUST_GATHER_DIR}"
oc --kubeconfig="${SHARED_DIR}/kubeconfig" adm must-gather --dest-dir="${MUST_GATHER_DIR}"
find "${MUST_GATHER_DIR}" -type f -path '*/cluster-scoped-resources/machineconfiguration.openshift.io/*' -exec sh -c 'echo "REDACTED" > "$1" && mv "$1" "$1.redacted"' _ {} \;

tar -czC "${MUST_GATHER_DIR}" -f "${ARTIFACT_DIR}/must-gather.tar.gz" .
rm -rf "${MUST_GATHER_DIR}"
