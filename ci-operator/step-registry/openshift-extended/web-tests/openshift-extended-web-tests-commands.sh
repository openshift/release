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
    ./console-test-managed-service.sh || true
  elif [[ $E2E_RUN_TAGS =~ @level0 ]]; then
    echo "only run level0 scenarios"
    ./console-test-frontend.sh --tags @level0 || true
  # if the TYPE is ui, then it's a job specific for UI, run full tests
  # or else, we run smoke tests to balance coverage and cost
  elif [[ "X${E2E_TEST_TYPE}X" == 'XuiX' ]]; then
    echo "Testing on normal cluster"
    ./console-test-frontend.sh --tags @userinterface+@e2e || true
  elif [[ "X${E2E_RUN_TAGS}X" == 'XNetwork_ObservabilityX' ]]; then
    # not using --grepTags here since cypress in 4.12 doesn't have that plugin
    echo "Running Network_Observability tests"
    ./console-test-frontend.sh --spec tests/netobserv/* || true
  elif [[ $E2E_RUN_TAGS =~ @wrs ]]; then
    # WRS specific testing
    echo 'WRS testing'
    ./console-test-frontend.sh --tags @wrs || true
  elif [[ $E2E_TEST_TYPE == 'ui_destructive' ]]; then
    echo 'Running destructive tests'
    ./console-test-frontend.sh --tags @destructive || true
  else
    echo "only run smoke scenarios"
    ./console-test-frontend.sh --tags @smoke || true
  fi
fi

# summarize test results
echo "Summarizing test results..."
if ! [[ -d "${ARTIFACT_DIR:-'/default-non-exist-dir'}" ]] ; then
    echo "Artifact dir '${ARTIFACT_DIR}' not exist"
    exit 0
else
    echo "Artifact dir '${ARTIFACT_DIR}' exist"
    ls -lR "${ARTIFACT_DIR}"
    files="$(find "${ARTIFACT_DIR}" -name '*.xml' | wc -l)"
    if [[ "$files" -eq 0 ]] ; then
        echo "There are no JUnit files"
        exit 0
    fi
fi
declare -A results=([failures]='0' [errors]='0' [skipped]='0' [tests]='0')
grep -r -E -h -o 'testsuite.*tests="[0-9]+"[^>]*' "${ARTIFACT_DIR}/gui_test_screenshots/console-cypress.xml" 2>/dev/null > /tmp/zzz-tmp.log || exit 0
while read row ; do
    for ctype in "${!results[@]}" ; do
        count="$(sed -E "s/.*$ctype=\"([0-9]+)\".*/\1/" <<< $row)"
        if [[ -n $count ]] ; then
            let results[$ctype]+=count || true
        fi
    done
done < /tmp/zzz-tmp.log

TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
cat > "${TEST_RESULT_FILE}" <<- EOF
openshift-extended-web-tests:
  total: ${results[tests]}
  failures: ${results[failures]}
  errors: ${results[errors]}
  skipped: ${results[skipped]}
EOF

if [ ${results[failures]} != 0 ] ; then
    echo '  failingScenarios:' >> "${TEST_RESULT_FILE}"
    readarray -t failingscenarios < <(find "${ARTIFACT_DIR}" -name 'cypress_report*.json' -exec yq '.results[].suites[].tests[] | select(.fail == true) | .fullTitle' {} \; | sort --unique)
    for (( i=0; i<${#failingscenarios[@]}; i++ )) ; do
        echo "    - ${failingscenarios[$i]}" >> "${TEST_RESULT_FILE}"
    done
fi
cat "${TEST_RESULT_FILE}" | tee -a "${SHARED_DIR}/openshift-e2e-test-qe-report" || true
