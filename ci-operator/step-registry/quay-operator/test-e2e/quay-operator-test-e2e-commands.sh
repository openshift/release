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

# Mailpit HTTP API base URL for email-dependent specs (utils/mailpit.ts). Written
# by the quay-operator-deploy-mailpit step. Left unset when mailing is disabled.
if [[ -s "${SHARED_DIR}/mailpit_api" ]]; then
  MAILPIT_API=$(cat "${SHARED_DIR}/mailpit_api")
  export MAILPIT_API
  echo "MAILPIT_API=${MAILPIT_API}"
else
  echo "No mailpit_api in SHARED_DIR; email-dependent specs may skip or fail"
fi

PLAYWRIGHT_WORKDIR="/go/src/github.com/quay/quay/web"
PLAYWRIGHT_GIT_REPO="${PLAYWRIGHT_GIT_REPO:-https://github.com/quay/quay.git}"

# Gangway / rehearsal override wins over PLAYWRIGHT_GIT_BRANCH.
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_PLAYWRIGHT_GIT_BRANCH:-}" ]]; then
  PLAYWRIGHT_GIT_BRANCH="${MULTISTAGE_PARAM_OVERRIDE_PLAYWRIGHT_GIT_BRANCH}"
fi

clone_playwright_sources() {
  local repo="$1"
  local branch="$2"
  local dest="$3"

  rm -rf "${dest}"
  mkdir -p "${dest}"
  export GIT_TERMINAL_PROMPT=0

  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 --branch "${branch}" "${repo}" "${dest}"
    return
  fi

  echo "git is not installed; downloading archive for ${branch}..."
  local archive
  archive="$(mktemp /tmp/quay-src.XXXXXX.tar.gz)"
  local base="${repo%.git}"
  if curl -fsSL "${base}/archive/refs/heads/${branch}.tar.gz" -o "${archive}"; then
    :
  elif curl -fsSL "${base}/archive/refs/tags/${branch}.tar.gz" -o "${archive}"; then
    :
  else
    echo "ERROR: failed to download ${repo} at ${branch}" >&2
    rm -f "${archive}"
    exit 1
  fi
  tar -xzf "${archive}" --strip-components=1 -C "${dest}"
  rm -f "${archive}"
}

# Default: use tests and browsers baked into quay-playwright-runner (same git
# ref as the image build). Clone only when PLAYWRIGHT_GIT_BRANCH is set.
if [[ -n "${PLAYWRIGHT_GIT_BRANCH:-}" ]]; then
  CLONE_DIR="/tmp/quay-playwright-src"
  echo "Cloning Playwright tests from ${PLAYWRIGHT_GIT_REPO} (branch ${PLAYWRIGHT_GIT_BRANCH})"
  clone_playwright_sources "${PLAYWRIGHT_GIT_REPO}" "${PLAYWRIGHT_GIT_BRANCH}" "${CLONE_DIR}"
  PLAYWRIGHT_WORKDIR="${CLONE_DIR}/web"
  if [[ ! -d "${PLAYWRIGHT_WORKDIR}" ]]; then
    echo "ERROR: cloned sources have no web/ directory at ${PLAYWRIGHT_WORKDIR}" >&2
    exit 1
  fi

  echo "Installing npm dependencies for Playwright branch ${PLAYWRIGHT_GIT_BRANCH}..."
  pushd "${PLAYWRIGHT_WORKDIR}"
  npm ci

  # Image browsers live in /opt/playwright as root. Test pods cannot write there.
  IMAGE_BROWSERS=/opt/playwright
  if [[ -d "${IMAGE_BROWSERS}" && -w "${IMAGE_BROWSERS}" ]]; then
    export PLAYWRIGHT_BROWSERS_PATH="${IMAGE_BROWSERS}"
  else
    export PLAYWRIGHT_BROWSERS_PATH=/tmp/playwright-browsers
    mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}"
    if [[ -d "${IMAGE_BROWSERS}" ]]; then
      echo "Seeding writable browser cache from ${IMAGE_BROWSERS}..."
      cp -a "${IMAGE_BROWSERS}/." "${PLAYWRIGHT_BROWSERS_PATH}/" || true
    fi
  fi
  echo "PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH}"
  npx playwright install chromium
  popd
else
  echo "Using Playwright tests from image at ${PLAYWRIGHT_WORKDIR} (PLAYWRIGHT_GIT_BRANCH unset)"
  if [[ ! -d "${PLAYWRIGHT_WORKDIR}" ]]; then
    echo "ERROR: image is missing ${PLAYWRIGHT_WORKDIR}" >&2
    exit 1
  fi
fi

function copyArtifacts {
  echo "Copying test artifacts..."
  local src="${PLAYWRIGHT_WORKDIR:-.}"
  cp -r "${src}"/test-results/* "${ARTIFACT_DIR}/" 2>/dev/null || true
  # Rename JUnit reports with junit_ prefix for Prow
  for file in "${ARTIFACT_DIR}"/*.xml; do
    if [[ -f "${file}" ]] && [[ ! "$(basename "${file}")" =~ ^junit_ ]]; then
      mv "${file}" "${ARTIFACT_DIR}/junit_$(basename "${file}")"
    fi
  done
  cp -r "${src}"/playwright-report/* "${ARTIFACT_DIR}/" 2>/dev/null || true
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

# IPI cluster ingress certs are not in Node's trust store. global-setup.ts uses
# Node fetch() for GET ${API_URL}/config (not Playwright request, which has
# ignoreHTTPSErrors). Without this, config fetch throws and smoke tests never run.
export NODE_TLS_REJECT_UNAUTHORIZED=0

# Tests excluded from the run. Beyond unsupported auth backends (OIDC/LDAP), this
# quarantines webhook tests (out of scope) plus tests tracking known product bugs
# and UI/version gaps. See E2E_FAILURE_REPORT.md for the rationale per entry.
PLAYWRIGHT_GREP_INVERT="${PLAYWRIGHT_GREP_INVERT:-@auth:OIDC|@auth:LDAP}"
echo "Excluding tests matching: ${PLAYWRIGHT_GREP_INVERT}"

echo "Running Playwright smoke tests from ${PLAYWRIGHT_WORKDIR} (branch ${PLAYWRIGHT_GIT_BRANCH:-image})..."
pushd "${PLAYWRIGHT_WORKDIR}"
npx playwright test \
  --grep-invert "${PLAYWRIGHT_GREP_INVERT}" \
  --reporter=junit,html \
  2>&1 | tee "${ARTIFACT_DIR}/playwright-output.log"
popd
