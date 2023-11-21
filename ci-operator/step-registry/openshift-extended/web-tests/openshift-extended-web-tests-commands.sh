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

## determine if it is hypershift guest cluster or not
if ! (oc get node --kubeconfig=${KUBECONFIG} | grep master) ; then
  echo "Testing on hypershift guest cluster"
  ./console-test-frontend-hypershift.sh || true
else
  export E2E_RUN_TAGS="${E2E_RUN_TAGS}"
  echo "E2E_RUN_TAGS is: ${E2E_RUN_TAGS}"
  ## determine if running against managed service or smoke scenarios
  if [[ $E2E_RUN_TAGS =~ @osd_ccs|@rosa ]] ; then
    echo "Testing against online cluster"
    ./console-test-osd.sh || true
  # if the TAGS contains @console, then it's a job specific for UI, run full tests
  # or else, we run smoke tests to balance coverage and cost
  elif [[ $E2E_RUN_TAGS =~ @console ]]; then
    echo "Testing on normal cluster"
    ./console-test-frontend.sh || true
  else
    echo "only run smoke scenarios"
    ./console-test-frontend.sh --tags @smoke || true
  fi
fi

# summarize test results
echo "Summarizing test result..."
failures=0 errors=0 skipped=0 tests=0
grep -r -E -h -o 'testsuite[^>]+' "${ARTIFACT_DIR}/gui_test_screenshots/console-cypress.xml" 2>/dev/null | tr -d '[A-Za-z="_]' > /tmp/zzz-tmp.log
while read -a row ; do
    # if the last ARG of command `let` evaluates to 0, `let` returns 1
    let errors+=${row[0]} failures+=${row[1]} skipped+=${row[2]} tests+=${row[3]} || true
done < /tmp/zzz-tmp.log

TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results"
echo -e "\nfailures: $failures, errors: $errors, skipped: $skipped, tests: $tests in openshift-extended-web-tests" | tee -a "${TEST_RESULT_FILE}"
if [ $((failures)) != 0 ] ; then
    echo "Failing Scenarios:" | tee -a "${TEST_RESULT_FILE}"
    find "${ARTIFACT_DIR}" -name 'cypress_report*.json' -exec yq '.results[].suites[].tests[] | select(.fail == true) | .fullTitle' {} \; | sed -E 's/^( +)?/  /' | tee -a "${TEST_RESULT_FILE}" || true
fi
cat "${TEST_RESULT_FILE}" >> "${SHARED_DIR}/openshift-e2e-test-qe-report" || true
