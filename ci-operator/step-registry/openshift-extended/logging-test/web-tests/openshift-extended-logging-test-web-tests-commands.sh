#!/bin/bash

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

pwd && ls -ltr
cd frontend || exit 0
pwd && ls -ltr

## skip all tests when console is not installed
if ! (oc get clusteroperator console --kubeconfig=${KUBECONFIG}) ; then
  echo "console is not installed, skipping all console tests."
  exit 0
fi

## set extra env vars for logging test
export CYPRESS_EXTRA_PARAM="{\"openshift-logging\": {\"cluster-logging\": {\"channel\": \"${CLO_SUB_CHANNEL}\", \"source\": \"${CLO_SUB_SOURCE}\"}, \"elasticsearch-operator\": {\"channel\": \"${EO_SUB_CHANNEL}\", \"source\": \"${EO_SUB_SOURCE}\"}, \"loki-operator\": {\"channel\": \"${LO_SUB_CHANNEL}\", \"source\": \"${LO_SUB_SOURCE}\"}}}"

echo "Start to test logging web cases"
export E2E_RUN_TAGS="${E2E_RUN_TAGS}"
echo "E2E_RUN_TAGS is: ${E2E_RUN_TAGS}"

run_shell="console-test-frontend.sh"
if [[ $E2E_RUN_TAGS =~ @osd_ccs|@rosa ]] ; then
    run_shell="console-test-managed-service.sh"
fi
## determine if it is hypershift guest cluster or not
if ! (oc get node --kubeconfig=${KUBECONFIG} | grep master) ; then
    run_shell="console-test-frontend-hypershift.sh"
fi

if [[ $E2E_RUN_TAGS =~ @level0 ]]; then
    echo "only run level0 scenarios"
    ./${run_shell} --spec ./tests/logging/ --tags @level0 || true
else
    ./${run_shell} --spec ./tests/logging/ || true
fi

# summarize test results
echo "Summarizing test results..."
failures=0 errors=0 skipped=0 tests=0
grep -r -E -h -o 'testsuite[^>]+' "${ARTIFACT_DIR}/gui_test_screenshots/console-cypress.xml" 2>/dev/null | tr -d '[A-Za-z="_]' > /tmp/zzz-tmp.log
while read -a row ; do
    # if the last ARG of command `let` evaluates to 0, `let` returns 1
    let errors+=${row[0]} failures+=${row[1]} skipped+=${row[2]} tests+=${row[3]} || true
done < /tmp/zzz-tmp.log

TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
cat > "${TEST_RESULT_FILE}" <<- EOF
openshift-extended-logging-test-web-tests:
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
