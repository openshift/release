#!/bin/bash
#
# Stage.quay.io Playwright Validation Tests
#
# Replaces the Cypress-based quay-tests-stagequayio step. Clones the quay.git
# repo and runs the @stage-validation Playwright tests against stage.quay.io
# using the QE bearer token.
#
# Credentials are mounted from the existing quay-qe-stagequayio-secret:
#   /var/run/quay-qe-stagequayio-secret/username
#   /var/run/quay-qe-stagequayio-secret/password
#   /var/run/quay-qe-stagequayio-secret/oauth2token

set -euo pipefail
set -x

ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

# ---------------------------------------------------------------------------
# Read credentials from Prow secret mount
# ---------------------------------------------------------------------------
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
QUAY_USER=$(cat /var/run/quay-qe-stagequayio-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-stagequayio-secret/password)
QUAY_API_TOKEN=$(cat /var/run/quay-qe-stagequayio-secret/oauth2token)
$WAS_TRACING && set -x

# ---------------------------------------------------------------------------
# Configure environment for Playwright stage validation
# ---------------------------------------------------------------------------
export PLAYWRIGHT_BASE_URL="https://stage.quay.io"
export REACT_QUAY_APP_API_URL="https://stage.quay.io"
export QUAY_API_TOKEN
export QUAY_USER
export QUAY_PASSWORD
export PLAYWRIGHT_SKIP_WEBSERVER=1
export CI=true
export NODE_TLS_REJECT_UNAUTHORIZED=0

# ---------------------------------------------------------------------------
# Optional: run Python push/pull scripts for redundant coverage
# ---------------------------------------------------------------------------
if [[ -d "utility" ]]; then
  python3 utility/quayio_test_push_images.py -n 20 > "${ARTIFACT_DIR}/stage_quay_io_push_image_report" 2>&1 || true
  python3 utility/quayio_test_pull_images.py -n 100 > "${ARTIFACT_DIR}/stage_quay_io_pull_image_report" 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Clone Playwright tests from quay.git
# ---------------------------------------------------------------------------
PLAYWRIGHT_GIT_REPO="${PLAYWRIGHT_GIT_REPO:-https://github.com/quay/quay.git}"
PLAYWRIGHT_GIT_BRANCH="${PLAYWRIGHT_GIT_BRANCH:-master}"
CLONE_DIR="/tmp/quay-playwright-src"

echo "Cloning Playwright tests from ${PLAYWRIGHT_GIT_REPO} (ref ${PLAYWRIGHT_GIT_BRANCH})"
rm -rf "${CLONE_DIR}"
if [[ "${PLAYWRIGHT_GIT_BRANCH}" =~ ^[0-9a-f]{40}$ ]]; then
  git init -q "${CLONE_DIR}"
  git -C "${CLONE_DIR}" remote add origin "${PLAYWRIGHT_GIT_REPO}"
  git -C "${CLONE_DIR}" fetch --depth 1 origin "${PLAYWRIGHT_GIT_BRANCH}"
  git -C "${CLONE_DIR}" checkout -q FETCH_HEAD
else
  git clone --depth 1 --branch "${PLAYWRIGHT_GIT_BRANCH}" "${PLAYWRIGHT_GIT_REPO}" "${CLONE_DIR}"
fi

PLAYWRIGHT_WORKDIR="${CLONE_DIR}/web"
if [[ ! -d "${PLAYWRIGHT_WORKDIR}" ]]; then
  echo "ERROR: cloned sources have no web/ directory" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Install dependencies and browser
# ---------------------------------------------------------------------------
echo "Installing npm dependencies..."
pushd "${PLAYWRIGHT_WORKDIR}"
npm ci

# Use image-bundled browsers if available, otherwise install
IMAGE_BROWSERS=/opt/playwright
if [[ -d "${IMAGE_BROWSERS}" && -w "${IMAGE_BROWSERS}" ]]; then
  export PLAYWRIGHT_BROWSERS_PATH="${IMAGE_BROWSERS}"
else
  export PLAYWRIGHT_BROWSERS_PATH=/tmp/playwright-browsers
  mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}"
  if [[ -d "${IMAGE_BROWSERS}" ]]; then
    cp -a "${IMAGE_BROWSERS}/." "${PLAYWRIGHT_BROWSERS_PATH}/" || true
  fi
fi
npx playwright install chromium

# ---------------------------------------------------------------------------
# Copy artifacts on exit
# ---------------------------------------------------------------------------
function copyArtifacts {
  echo "Copying test artifacts..."
  cp -r test-results/* "${ARTIFACT_DIR}/" 2>/dev/null || true
  for file in "${ARTIFACT_DIR}"/*.xml; do
    if [[ -f "${file}" ]] && [[ ! "$(basename "${file}")" =~ ^junit_ ]]; then
      mv "${file}" "${ARTIFACT_DIR}/junit_$(basename "${file}")"
    fi
  done
  cp -r playwright-report/* "${ARTIFACT_DIR}/" 2>/dev/null || true
}
trap copyArtifacts EXIT

# ---------------------------------------------------------------------------
# Run stage-validation tests
# ---------------------------------------------------------------------------
export PLAYWRIGHT_JUNIT_OUTPUT_NAME="${ARTIFACT_DIR}/junit_playwright_stage_validation.xml"

echo "Running Playwright stage-validation tests against ${PLAYWRIGHT_BASE_URL}..."
npx playwright test \
  --grep "@stage-validation" \
  --workers=1 \
  --reporter=junit,html \
  2>&1 | tee "${ARTIFACT_DIR}/playwright-stage-validation-output.log"

popd
