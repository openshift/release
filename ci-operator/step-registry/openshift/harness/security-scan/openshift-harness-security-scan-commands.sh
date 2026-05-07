#!/bin/bash

set -euo pipefail

LLM_FLAG=""
if [[ "${USE_LLM}" == "true" ]]; then
  LLM_FLAG="--use-llm"
  echo "Running skill-scanner with LLM-based semantic analysis..."
  echo "Model: ${SKILL_SCANNER_LLM_MODEL}"
else
  echo "Running skill-scanner with static rules only (LLM disabled)..."
fi

# shellcheck disable=SC2086
skill-scanner scan-all . --recursive --check-overlap ${LLM_FLAG} \
  --fail-on-severity medium \
  --format json \
  --output-json "${ARTIFACT_DIR}/skill-scanner-report.json" \
  --format html \
  --output-html "${ARTIFACT_DIR}/skill-scanner-summary.html" \
  ${SCAN_ADDITIONAL_ARGS}
