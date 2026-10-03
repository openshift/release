#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# Run Quay smoke tests via openshift-tests with local extension binary
openshift-tests run-suite interop/quay \
  --extension-local-binaries /usr/bin/quay-tests-ext.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
