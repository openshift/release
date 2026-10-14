#!/bin/bash

set -euo pipefail

ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

QUAY_ROUTE=$(cat "${SHARED_DIR}/quayroute")
if [[ -z "${QUAY_ROUTE}" ]]; then
  echo "ERROR: quayroute is empty in SHARED_DIR" >&2
  exit 1
fi
# quay-api-tests wants the endpoint with its scheme and the bare hostname.
export CYPRESS_QUAY_ENDPOINT=${QUAY_ROUTE}
export CYPRESS_QUAY_HOSTNAME=${QUAY_ROUTE#*://}
export CYPRESS_QUAY_VERSION=${QUAY_VERSION}
echo "Quay version under test: ${CYPRESS_QUAY_VERSION}"

# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
CYPRESS_QUAY_USER=$(cat /var/run/quay-qe-quay-secret/username)
CYPRESS_QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
export CYPRESS_QUAY_USER CYPRESS_QUAY_PASSWORD
$WAS_TRACING && set -x

cd quay-api-tests
npm install --no-audit --no-fund

rc=0
NO_COLOR=1 node_modules/.bin/cypress run -b electron --spec "${API_LEGACY_SPECS}" \
  --reporter mocha-junit-reporter \
  --reporter-options "mochaFile=${ARTIFACT_DIR}/junit_api_legacy-[hash].xml" \
  --config "videosFolder=${ARTIFACT_DIR}/videos,screenshotsFolder=${ARTIFACT_DIR}/screenshots" || rc=$?
tests=$(cat "${ARTIFACT_DIR}"/junit_api_legacy-*.xml 2>/dev/null | grep -o '<testcase' | wc -l || true)
echo "Cypress API run: exit code ${rc}, JUnit test cases: ${tests}"
if [[ "${tests}" -eq 0 ]]; then
  echo "ERROR: API run JUnit output has 0 tests" >&2
  rc=1
fi
exit "${rc}"
