#!/bin/bash

set -euo pipefail

# Gate the post-phase full openshift-extended-test run on the test-phase smoke
# gate. TEST_SCENARIOS is provided by the prowjob; this step only blanks it
# (via runtime_env, which openshift-extended-test sources before reading
# TEST_SCENARIOS) when the smoke marker is absent, so the full run self-skips
# instead of failing on a broken cluster.
MARKER="${SHARED_DIR}/osc-post-smoke-ok"
RUNTIME_ENV="${SHARED_DIR}/runtime_env"

if [[ -f "${MARKER}" ]]; then
    echo "Smoke marker ${MARKER} present: leaving TEST_SCENARIOS as provided by the prowjob for the full post-phase run."
    exit 0
fi

echo "Smoke marker ${MARKER} absent: blanking TEST_SCENARIOS so the post-phase openshift-extended-test self-skips."
echo 'export TEST_SCENARIOS=""' >> "${RUNTIME_ENV}"
