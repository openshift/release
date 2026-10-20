#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

# Run ODF smoke tests via openshift-tests with local extension binary
openshift-tests run-suite odf/smoke \
  --extension-local-binaries /usr/bin/odf-tests-ext.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
