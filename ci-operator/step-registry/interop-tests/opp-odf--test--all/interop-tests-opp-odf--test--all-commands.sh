#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# Run all ODF tests via openshift-tests with local extension binary
openshift-tests run-suite odf/all \
  --extension-local-binaries /usr/bin/odf-tests-ext.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
