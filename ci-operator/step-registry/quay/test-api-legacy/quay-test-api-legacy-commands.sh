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

# Run as a per-run superuser: QUAY_API_SUPERUSER must be in SUPER_USERS.
# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
export CYPRESS_QUAY_USER=${QUAY_API_SUPERUSER}
CYPRESS_QUAY_PASSWORD=$(set +o pipefail; LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 24)
export CYPRESS_QUAY_PASSWORD
body=$(jq -n --arg u "${CYPRESS_QUAY_USER}" --arg p "${CYPRESS_QUAY_PASSWORD}" \
  '{username: $u, password: $p, email: ($u + "@example.com")}')
code=$(curl -sk -o /tmp/create-user.json -w '%{http_code}' -X POST "${QUAY_ROUTE}/api/v1/user/" \
  -H 'Content-Type: application/json' --data "${body}" || true)
unset body
$WAS_TRACING && set -x
if [[ "${code}" != "200" ]]; then
  echo "ERROR: creating Quay user ${CYPRESS_QUAY_USER} returned HTTP ${code}: $(cat /tmp/create-user.json 2>/dev/null)" >&2
  exit 1
fi
echo "Created Quay user ${CYPRESS_QUAY_USER}"

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
