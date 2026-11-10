#!/bin/bash

set -euo pipefail

if [[ -n "${TEST_PLAN:-}" ]]; then
    # Always write as .yaml since all JSON is valid YAML, and the YAML parser handles both.
    echo "${TEST_PLAN}" > "${SHARED_DIR}/test-plan.yaml"
    echo "Wrote test plan to ${SHARED_DIR}/test-plan.yaml"
fi
