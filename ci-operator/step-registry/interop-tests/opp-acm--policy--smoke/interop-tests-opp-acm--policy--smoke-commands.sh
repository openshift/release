#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# Run ACM policy smoke tests via openshift-tests with local extension binary
openshift-tests run-suite policy-collection/smoke \
  --extension-local-binaries /usr/bin/stolostron-policy-collection-ext.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
