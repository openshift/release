#!/bin/bash

set -euo pipefail
set -x

ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

# Read the Quay route written by the deploy step
QUAY_ROUTE=$(cat "${SHARED_DIR}/quayroute")
if [[ -z "${QUAY_ROUTE}" ]]; then
  echo "ERROR: quayroute not found in SHARED_DIR" >&2
  exit 1
fi
echo "Quay route: ${QUAY_ROUTE}"

# Read credentials
# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
$WAS_TRACING && set -x

# Configure Playwright environment
# PLAYWRIGHT_BASE_URL: browser navigation URL (Quay UI)
# REACT_QUAY_APP_API_URL: backend API URL (same as UI on OCP)
export PLAYWRIGHT_BASE_URL="${QUAY_ROUTE}"
export REACT_QUAY_APP_API_URL="${QUAY_ROUTE}"
export PLAYWRIGHT_JUNIT_OUTPUT_NAME="${ARTIFACT_DIR}/junit_playwright.xml"
export PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
export QUAY_USERNAME
export QUAY_PASSWORD
export CI=true

# WORKDIR is already set to the web/ directory by the quay-playwright-runner image

function copyArtifacts {
  echo "Copying test artifacts..."
  cp -r test-results/* "${ARTIFACT_DIR}/" 2>/dev/null || true
  # Rename JUnit reports with junit_ prefix for Prow
  for file in "${ARTIFACT_DIR}"/*.xml; do
    if [[ -f "${file}" ]] && [[ ! "$(basename "${file}")" =~ ^junit_ ]]; then
      mv "${file}" "${ARTIFACT_DIR}/junit_$(basename "${file}")"
    fi
  done
  cp -r playwright-report/* "${ARTIFACT_DIR}/" 2>/dev/null || true
}
trap copyArtifacts EXIT

# Pre-create test users so Playwright's global-setup finds them already existing.
# Without this, POST /api/v1/user/ auto-signs in the new user via common_login(),
# which calls generate_csrf_token(force=True) — replacing the session CSRF token.
# The Playwright ApiClient caches the old token and reuses it for signIn(), causing
# a CSRF mismatch (403). When users already exist, createUser() gets "already exists"
# which skips common_login(), keeping the cached CSRF token valid.
echo "Pre-creating Playwright test users..."
set +x
for USER_JSON in \
  '{"username":"admin","password":"password","email":"admin@example.com"}' \
  '{"username":"testuser","password":"password","email":"testuser@example.com"}' \
  '{"username":"readonly","password":"password","email":"readonly@example.com"}'; do

  UNAME=$(echo "${USER_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")

  CSRF=$(curl -sk -c /tmp/csrf_cookies -H 'X-Requested-With: XMLHttpRequest' \
    "${QUAY_ROUTE}/csrf_token" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('csrf_token',''))" 2>/dev/null) || true

  if [[ -n "${CSRF}" ]]; then
    HTTP_CODE=$(curl -sk -b /tmp/csrf_cookies -o /dev/null -w '%{http_code}' \
      -X POST "${QUAY_ROUTE}/api/v1/user/" \
      -H 'Content-Type: application/json' \
      -H "X-CSRF-Token: ${CSRF}" \
      -d "${USER_JSON}") || true
    echo "  ${UNAME}: ${HTTP_CODE}"
  else
    echo "  ${UNAME}: skipped (no CSRF token)"
  fi
  rm -f /tmp/csrf_cookies
done
$WAS_TRACING && set -x
echo "Test user pre-creation complete"

echo "Running Playwright tests..."
npx playwright test \
  --reporter=junit,html \
  2>&1 | tee "${ARTIFACT_DIR}/playwright-output.log"
