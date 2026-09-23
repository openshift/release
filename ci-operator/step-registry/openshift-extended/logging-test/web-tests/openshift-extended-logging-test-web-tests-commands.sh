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

## determine if it is hypershift guest cluster or not
if ! (oc get node --kubeconfig=${KUBECONFIG} | grep master) ; then
  echo "Skip logging web test as console-test-frontend-hypershift.sh can not select cases" || exit 0
  #./console-test-frontend-hypershift.sh || true
elif [[ $E2E_RUN_TAGS =~ @osd_ccs|@rosa ]] ; then
  echo "Skip logging web test as console-test-managed-service.sh can not select case" || exit 0
  #./console-test-managed-service.sh || true
else
  if [[ $E2E_RUN_TAGS == @logging ]]; then
    echo "run all logging scenarios"
    ./console-test-frontend.sh --tags @logging || true
  elif [[ $E2E_RUN_TAGS =~ @level0 ]]; then
    echo "only run logging level0 scenarios"
    ./console-test-frontend.sh --tags @logging+@level0 || true
  elif [[ $E2E_RUN_TAGS =~ @wrs ]]; then
    echo "only run logging wrs scenarios"
    ./console-test-frontend.sh --tags @logging+@wrs || true
  elif [[ $E2E_RUN_TAGS =~ @smoke ]]; then
    echo "only run logging smoke scenarios"
    ./console-test-frontend.sh --tags @logging+@smoke || true
  else
    echo "run all logging web scenarios"
    ./console-test-frontend.sh --spec tests/logging/* || true
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
openshift-extended-logging-test-web-tests:
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
