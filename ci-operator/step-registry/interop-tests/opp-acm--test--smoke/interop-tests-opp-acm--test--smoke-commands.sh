#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

# Run ACM lifecycle smoke tests via openshift-tests with local extension binary
openshift-tests run-suite acm-lifecycle/smoke \
  --extension-local-binaries /usr/bin/acm-tests-ext.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
