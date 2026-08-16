#!/bin/bash

set -euo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}/test-results" "${ARTIFACT_DIR}/playwright-report"

quay_route="$(< "${SHARED_DIR}/quay-pr-smoke-route")"
if [[ -z "${quay_route}" ]]; then
  echo "Quay route is missing" >&2
  exit 1
fi

export CI=true
export OPENSHIFT_CI=true
export PLAYWRIGHT_BASE_URL="${quay_route}"
export REACT_QUAY_APP_API_URL="${quay_route}"
export PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
export PLAYWRIGHT_JUNIT_OUTPUT_NAME="${ARTIFACT_DIR}/junit_playwright.xml"
export PLAYWRIGHT_HTML_OUTPUT_DIR="${ARTIFACT_DIR}/playwright-report"
export PLAYWRIGHT_JSON_OUTPUT_NAME="${ARTIFACT_DIR}/playwright-results.json"
export PLAYWRIGHT_OUTPUT_DIR="${ARTIFACT_DIR}/test-results"

echo "Running the OpenShift core Playwright tag selection"
set +e
npx playwright test \
  --grep '@smoke|@critical|@container' \
  --grep-invert '@webhook' \
  --reporter=list,junit,html,json \
  --output="${ARTIFACT_DIR}/test-results" \
  2>&1 | tee "${ARTIFACT_DIR}/playwright-output.log"
playwright_status="${PIPESTATUS[0]}"
set -e

if [[ "${playwright_status}" == "0" && ! -s "${ARTIFACT_DIR}/junit_playwright.xml" ]]; then
  echo "Playwright returned success without producing JUnit" >&2
  playwright_status=1
fi
printf '%s\n' "${playwright_status}" >"${SHARED_DIR}/quay-pr-smoke-playwright-status"

if [[ "${playwright_status}" == "0" ]]; then
  echo "Playwright passed; cleanup will run before the final result step"
else
  echo "Playwright failed with status ${playwright_status}; cleanup will run before the final result step"
fi
