#!/bin/bash
set -euo pipefail

echo "=== HyperShift Eval Agents ==="

cd /go/src/github.com/openshift/hypershift

MAKE_ARGS="EVAL_OUTPUT=${ARTIFACT_DIR}/results.xml"

if [ -n "${EVAL_FOCUS:-}" ]; then
    echo "Filter: ${EVAL_FOCUS}"
    MAKE_ARGS="${MAKE_ARGS} EVAL_FILTER=${EVAL_FOCUS}"
fi

echo "Running eval-agents with promptfoo..."
make eval-agents ${MAKE_ARGS}

echo "=== Eval Agents Complete ==="
