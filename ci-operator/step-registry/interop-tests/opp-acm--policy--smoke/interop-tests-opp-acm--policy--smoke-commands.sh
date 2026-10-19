#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# Run ACM policy smoke tests via openshift-tests with local extension binary
# NOTE: Smoke suite is registered separately, but its current test membership matches the all suite; a distinct subset is pending.
openshift-tests run-suite acm/smoke \
  --extension-local-binaries /usr/bin/acm-policy-tests.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
