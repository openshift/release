#!/usr/bin/env bash

set -euo pipefail

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

pwd && ls -ltr
cd frontend
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
./console-test-azure-external-oidc.sh
ret=$?

echo "Summarizing test results"
set -x
ls -lR "${ARTIFACT_DIR}"

num_junit_files="$(find "${ARTIFACT_DIR}" -name '*.xml' | wc -l)"
if (( num_junit_files == 0 )); then
    echo "No JUnit files found"
    exit $ret
fi

console_file="${ARTIFACT_DIR}/gui_test_screenshots/console-cypress.xml"
temp_file="/tmp/zzz-tmp.log"
if ! grep -E -h -o 'testsuite.*tests="[0-9]+"[^>]*' "$console_file" > "$temp_file"; then
    echo "No testsuite found in ${ARTIFACT_DIR}/gui_test_screenshots/console-cypress.xml"
    exit $ret
fi

declare -A results=([failures]=0 [errors]=0 [skipped]=0 [tests]=0)
while read -r row; do
    for ctype in "${!results[@]}"; do
        count="$(sed -E "s/.*$ctype=\"([0-9]+)\".*/\1/" <<< "$row")"
        if [[ -n $count ]]; then
            results[$ctype]=$(( results[$ctype] + count ))
        fi
    done
done < "$temp_file"

TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
cat > "${TEST_RESULT_FILE}" <<- EOF
openshift-extended-web-tests-ext-oidc-cli-login:
  total: ${results[tests]}
  failures: ${results[failures]}
  errors: ${results[errors]}
  skipped: ${results[skipped]}
EOF

if (( results[failures] != 0 )); then
    echo '  failingScenarios:' >> "${TEST_RESULT_FILE}"
    readarray -t failingscenarios < <(find "${ARTIFACT_DIR}" -name 'cypress_report*.json' -exec yq '.results[].suites[].tests[] | select(.fail == true) | .fullTitle' {} \; | sort --unique)
    for (( i=0; i<${#failingscenarios[@]}; i++ )); do
        echo "    - ${failingscenarios[$i]}" >> "${TEST_RESULT_FILE}"
    done
fi

tee -a "${SHARED_DIR}/openshift-e2e-test-qe-report" < "${TEST_RESULT_FILE}"

# Fail the step in case external OIDC login failed
exit $ret
