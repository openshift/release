#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# Run ACM tests via openshift-tests with local extension binary
openshift-tests run-suite opp/acm \
  --extension-local-binaries /usr/bin/opp-tests-ext.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
