#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# Run ACS smoke tests via openshift-tests with local extension binary
openshift-tests run-suite acs/smoke \
  --extension-local-binaries /usr/bin/acs-tests.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
