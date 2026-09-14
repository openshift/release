#!/bin/bash

set -euo pipefail
# No -x: this step only echoes non-sensitive values. It does not print the
# kubeconfig or any credentials. It always exits 0 (see below).

# Enable-gate. Unlike the post suites this defaults to "true": the sanity suite
# is the producer of the post-suite gate, so it must run by default.
ENABLE="${TESTS_SANITY_ENABLE:-true}"

# The gate file the post suites read. Its presence means "sanity ran"; its
# content ("passed" vs anything else) means "sanity passed / failed".
GATE="${SHARED_DIR}/testsuites_gate"

echo "=========================================="
echo "OSC testsuites :: sanity (gate)"
echo "TESTS_SANITY_ENABLE=${ENABLE}"
echo "=========================================="

if [[ "${ENABLE}" != "true" ]]; then
    # Do NOT write the gate: leaving it absent makes every post suite abort,
    # which is the intended effect of disabling the sanity gate.
    echo "sanity suite disabled (TESTS_SANITY_ENABLE=${ENABLE}); gate not written."
    echo "All post-phase testsuites will abort (skip) because the gate is absent."
    exit 0
fi

# --- Sanity checks -----------------------------------------------------------
# TODO: implement the real sanity checks here (verify the cluster is healthy and
# the operator setup from the pre phase actually succeeded). On success, write
# "passed" to the gate; on failure, write a short "failed: <cause>" token so the
# reason surfaces in every skipped post suite's JUnit.
#
# For now this is a no-op that always passes.
RESULT="passed"

echo "${RESULT}" > "${GATE}"
echo "sanity result '${RESULT}' written to gate file (${GATE})."
exit 0
