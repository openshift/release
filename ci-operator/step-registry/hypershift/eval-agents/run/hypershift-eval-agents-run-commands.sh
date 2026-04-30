#!/bin/bash
set -euo pipefail

echo "=== HyperShift Eval Agents ==="

export EVAL_MODEL="${EVAL_MODEL:-claude-opus-4-6}"
export EVAL_JUDGE_MODEL="${EVAL_JUDGE_MODEL:-claude-opus-4-6}"
export EVAL_RUNS="${EVAL_RUNS:-1}"
export EVAL_THRESHOLD="${EVAL_THRESHOLD:-0.8}"

echo "Model: ${EVAL_MODEL}"
echo "Judge: ${EVAL_JUDGE_MODEL}"
echo "Runs: ${EVAL_RUNS}"
echo "Threshold: ${EVAL_THRESHOLD}"

cd /go/src/github.com/openshift/hypershift

if [ -n "${EVAL_FOCUS:-}" ]; then
    echo "Focus: ${EVAL_FOCUS}"
    make eval-agents EVAL_FOCUS="${EVAL_FOCUS}" EVAL_VERBOSE=1
else
    echo "Running all eval scenarios..."
    make eval-agents EVAL_VERBOSE=1
fi

echo "=== Eval Agents Complete ==="
