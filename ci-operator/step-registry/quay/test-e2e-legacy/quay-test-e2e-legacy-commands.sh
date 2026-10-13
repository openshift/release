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

# Reconfiguring tests run `oc login`, which writes the kubeconfig it uses.
cp -L "${KUBECONFIG}" /tmp/kubeconfig
export KUBECONFIG=/tmp/kubeconfig KUBECONFIG_PATH=/tmp/kubeconfig
CYPRESS_OCP_ENDPOINT=$(oc whoami --show-server)
export CYPRESS_OCP_ENDPOINT CYPRESS_OCP_USER=kubeadmin

# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
CYPRESS_OCP_PASSWORD=$(cat "${SHARED_DIR}/kubeadmin-password")
CYPRESS_QUAY_USER=$(cat /var/run/quay-qe-quay-secret/username)
CYPRESS_QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
export CYPRESS_OCP_PASSWORD CYPRESS_QUAY_USER CYPRESS_QUAY_PASSWORD
$WAS_TRACING && set -x

cd quay-frontend-tests
# npm ci rejects quay-tests' package-lock.json (out of sync with package.json).
npm install --no-audit --no-fund

rc=0
NO_COLOR=1 node_modules/.bin/cypress run -b electron \
  --spec "${E2E_LEGACY_SPECS}" \
  --env "grep=${E2E_LEGACY_GREP}" \
  --reporter mocha-junit-reporter \
  --reporter-options "mochaFile=${ARTIFACT_DIR}/junit_e2e_legacy-[hash].xml" \
  --config "videosFolder=${ARTIFACT_DIR}/videos,screenshotsFolder=${ARTIFACT_DIR}/screenshots" \
  || rc=$?

tests=$(cat "${ARTIFACT_DIR}"/junit_e2e_legacy-*.xml 2>/dev/null | grep -o '<testcase' | wc -l || true)
echo "Cypress exit code: ${rc}, JUnit test cases: ${tests}"
if [[ "${tests}" -eq 0 ]]; then
  echo "ERROR: JUnit output has 0 tests" >&2
  exit 1
fi
exit "${rc}"
