#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

# Run Quay smoke tests via openshift-tests with local extension binary
openshift-tests run-suite quay/smoke \
  --extension-local-binaries /usr/bin/quay-tests.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
