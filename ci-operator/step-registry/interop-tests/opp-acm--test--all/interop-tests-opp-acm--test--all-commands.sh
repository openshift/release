#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# Run all ACM lifecycle tests via openshift-tests with local extension binary
openshift-tests run-suite acm-lifecycle/all \
  --extension-local-binaries /usr/bin/acm-tests-ext.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
