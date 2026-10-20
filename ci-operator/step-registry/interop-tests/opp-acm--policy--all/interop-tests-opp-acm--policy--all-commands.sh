#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

# Run all ACM policy tests via openshift-tests with local extension binary
openshift-tests run-suite acm/all \
  --extension-local-binaries /usr/bin/acm-policy-tests.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
