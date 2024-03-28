#!/bin/bash

if [ -f "${SHARED_DIR}/proxy-conf.sh" ]; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

pwd && ls -ltr
cd frontend || exit 0
pwd && ls -ltr

## skip all tests when console is not installed
if ! (oc get clusteroperator console --kubeconfig=${KUBECONFIG}); then
  echo "console is not installed, skipping all console tests."
  exit 0
fi

echo "Start to test netobserv cases"
./console-test-frontend.sh --tags Network_Observability || exit 0

# summarize test results
echo "Summarizing test results..."
failures=0 errors=0 skipped=0 tests=0
grep -r -E -h -o 'testsuite[^>]+' "${ARTIFACT_DIR}/gui_test_screenshots/console-cypress.xml" 2>/dev/null | tr -d '[A-Za-z="_]' >/tmp/zzz-tmp.log
while read -a row; do
  # if the last ARG of command `let` evaluates to 0, `let` returns 1
  let errors+=${row[0]} failures+=${row[1]} skipped+=${row[2]} tests+=${row[3]} || true
done </tmp/zzz-tmp.log

TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
cat >"${TEST_RESULT_FILE}" <<-EOF
cypress:
  type: openshift-extended-netobserv-test-web-tests
  total: $tests
  failures: $failures
  errors: $errors
  skipped: $skipped
EOF

if [ $((failures)) != 0 ]; then
  echo '  failingScenarios:' >>"${TEST_RESULT_FILE}"
  readarray -t failingscenarios < <(find "${ARTIFACT_DIR}" -name 'cypress_report*.json' -exec yq '.results[].suites[].tests[] | select(.fail == true) | .fullTitle' {} \; | sort --unique)
  for ((i = 0; i < ${#failingscenarios[@]}; i++)); do
    echo "    - ${failingscenarios[$i]}" >>"${TEST_RESULT_FILE}"
  done
fi
cat "${TEST_RESULT_FILE}" | tee -a "${SHARED_DIR}/openshift-e2e-test-qe-report" || true
