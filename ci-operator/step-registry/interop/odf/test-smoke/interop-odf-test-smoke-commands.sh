#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# Run ODF tests via openshift-tests with local extension binary
openshift-tests run-suite opp/odf \
  --extension-local-binaries /usr/bin/opp-tests-ext.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
