#!/usr/bin/env bash

set -euo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

pwd && ls -ltr
cd frontend || exit 0
pwd && ls -ltr

echo "Making sure that the console is installed"
if ! oc get clusteroperator console; then
    echo "Console not installed, exiting"
    exit 1
fi

echo "Making sure that the active cluster is a Hypershift hosted cluster"
if oc get node | grep master; then
    echo "The active cluster is not a Hypershift hosted cluster, exiting"
    exit 1
fi

echo "Making sure that the active cluster is using external OIDC"
if ! (oc get authentication cluster -o=jsonpath='{.spec.type}' --kubeconfig="${KUBECONFIG}" | grep OIDC); then
    echo "The active cluster is not using external OIDC, exiting"
    exit 1
fi

echo "Exporting external-oidc-related environment variables"
export USER_EMAIL
USER_EMAIL="$(cat /var/run/hypershift-qe-ci-rh-sso-service-account/email)"
export USER
USER="$(cat /var/run/hypershift-qe-ci-rh-sso-service-account/rh-username)"
export PASSWORD
PASSWORD="$(cat /var/run/hypershift-qe-ci-rh-sso-service-account/rh-password)"
export issuer_url
issuer_url="$(cat /var/run/hypershift-ext-oidc-app-cli/issuer-url)"
export cli_client_id
cli_client_id="$(cat /var/run/hypershift-ext-oidc-app-cli/client-id)"

echo "Invoking console test script for external OIDC"
ret=0
./console-test-azure-external-oidc.sh || ret=$?

echo "Summarizing test results..."
failures=0 errors=0 skipped=0 tests=0
grep -r -E -h -o 'testsuite[^>]+' "${ARTIFACT_DIR}/gui_test_screenshots/console-cypress.xml" 2>/dev/null | tr -d '[A-Za-z="_]' > /tmp/zzz-tmp.log
while read -a row ; do
    # if the last ARG of command `let` evaluates to 0, `let` returns 1
    let errors+=${row[0]} failures+=${row[1]} skipped+=${row[2]} tests+=${row[3]} || true
done < /tmp/zzz-tmp.log

TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
cat > "${TEST_RESULT_FILE}" <<- EOF
openshift-extended-web-tests-ext-oidc-cli-login:
  total: $tests
  failures: $failures
  errors: $errors
  skipped: $skipped
EOF

if [ $((failures)) != 0 ] ; then
    echo '  failingScenarios:' >> "${TEST_RESULT_FILE}"
    readarray -t failingscenarios < <(find "${ARTIFACT_DIR}" -name 'cypress_report*.json' -exec yq '.results[].suites[].tests[] | select(.fail == true) | .fullTitle' {} \; | sort --unique)
    for (( i=0; i<${#failingscenarios[@]}; i++ )) ; do
        echo "    - ${failingscenarios[$i]}" >> "${TEST_RESULT_FILE}"
    done
fi
cat "${TEST_RESULT_FILE}" | tee -a "${SHARED_DIR}/openshift-e2e-test-qe-report" || true

echo "Checking if external OIDC login has succeeded or not"
if (( ret != 0 )); then
    echo "Failed to perform external OIDC login"
    exit 1
fi
