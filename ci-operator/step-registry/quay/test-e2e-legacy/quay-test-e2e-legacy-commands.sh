#!/bin/bash

set -euo pipefail

ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

QUAY_ROUTE=$(cat "${SHARED_DIR}/quayroute")
if [[ -z "${QUAY_ROUTE}" ]]; then
  echo "ERROR: quayroute is empty in SHARED_DIR" >&2
  exit 1
fi
export CYPRESS_QUAY_ENDPOINT=${QUAY_ROUTE#*://}
export CYPRESS_QUAY_VERSION=${QUAY_VERSION}
echo "Quay version under test: ${CYPRESS_QUAY_VERSION}"

# Run as a per-run superuser: QUAY_E2E_LEGACY_SUPERUSER must be in SUPER_USERS.
# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
export CYPRESS_QUAY_USER=${QUAY_E2E_LEGACY_SUPERUSER}
CYPRESS_QUAY_PASSWORD=$(set +o pipefail; LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 24)
export CYPRESS_QUAY_PASSWORD
# Quay's API rejects session POSTs without a CSRF token, so fetch one first.
cookies=/tmp/quay-cookies.txt
csrf=$(curl -sk -c "${cookies}" "${QUAY_ROUTE}/csrf_token" | jq -r '.csrf_token // empty' || true)
code=$(jq -n '{username: env.CYPRESS_QUAY_USER, password: env.CYPRESS_QUAY_PASSWORD,
  email: (env.CYPRESS_QUAY_USER + "@example.com")}' |
  curl -sk -o /tmp/create-user.json -w '%{http_code}' -X POST "${QUAY_ROUTE}/api/v1/user/" \
    -b "${cookies}" -H "X-CSRF-Token: ${csrf}" -H 'Content-Type: application/json' --data @- || true)
rm -f "${cookies}"
$WAS_TRACING && set -x
if [[ "${code}" != "200" ]]; then
  echo "ERROR: creating Quay user ${CYPRESS_QUAY_USER} returned HTTP ${code}: $(cat /tmp/create-user.json 2>/dev/null)" >&2
  exit 1
fi
echo "Created Quay user ${CYPRESS_QUAY_USER}"

cd quay-frontend-tests
# npm ci rejects quay-tests' package-lock.json (out of sync with package.json).
npm install --no-audit --no-fund

rc=0
# run_cypress <name> <cypress args...>: JUnit goes to junit_e2e_legacy-<name>-*.xml.
run_cypress() {
  local name=$1 code=0 tests
  shift
  NO_COLOR=1 node_modules/.bin/cypress run -b electron \
    --reporter mocha-junit-reporter \
    --reporter-options "mochaFile=${ARTIFACT_DIR}/junit_e2e_legacy-${name}-[hash].xml" \
    --config "videosFolder=${ARTIFACT_DIR}/videos,screenshotsFolder=${ARTIFACT_DIR}/screenshots,trashAssetsBeforeRuns=false" \
    "$@" || code=$?
  tests=$(cat "${ARTIFACT_DIR}"/junit_e2e_legacy-"${name}"-*.xml 2>/dev/null | grep -o '<testcase' | wc -l || true)
  echo "Cypress ${name} run: exit code ${code}, JUnit test cases: ${tests}"
  if [[ "${tests}" -eq 0 ]]; then
    echo "ERROR: ${name} run JUnit output has 0 tests" >&2
    code=1
  fi
  [[ "${code}" -eq 0 ]] || rc=${code}
}
run_cypress specs --spec "${E2E_LEGACY_SPECS}"
# grepOmitFiltered drops filtered tests, so their suites' before() hooks never run.
run_cypress grep --spec "${E2E_LEGACY_GREP_SPECS}" --env "grep=${E2E_LEGACY_GREP},grepOmitFiltered=true"
exit "${rc}"
