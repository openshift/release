#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function set_cluster_access() {
    if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
        export KUBECONFIG=${SHARED_DIR}/kubeconfig
	echo "KUBECONFIG: ${KUBECONFIG}"
    fi
    cp -Lrvf "${KUBECONFIG}" /tmp/kubeconfig
    if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
        source "${SHARED_DIR}/proxy-conf.sh"
	echo "proxy: ${SHARED_DIR}/proxy-conf.sh"
    fi
}
function preparation_for_test() {
    if ! which kubectl > /dev/null ; then
        mkdir --parents /tmp/bin
        export PATH=$PATH:/tmp/bin
        ln --symbolic "$(which oc)" /tmp/bin/kubectl
    fi
    #shellcheck source=${SHARED_DIR}/runtime_env
    source "${SHARED_DIR}/runtime_env"
}
function test_execution_cucumber() {
    local test_type type_tags
    test_type="$1"
    type_tags="$2"
    export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/${test_type}"
    export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS="${USERS}"
    set -x
    cucumber --tags "${E2E_RUN_TAGS} and ${type_tags}" -p junit || true
    set +x
}
function test_execution() {
    pushd verification-tests
    export E2E_RUN_TAGS="${E2E_RUN_TAGS}"
    test_execution_cucumber 'logging1' 'not @console'
    test_execution_cucumber 'logging2' '@console'
    popd
}
function summarize_test_results() {
    # summarize test results
    echo "Summarizing test results..."
    failures=0 errors=0 skipped=0 tests=0
    grep -r -E -h -o 'testsuite.*tests="[0-9]+"' "${ARTIFACT_DIR}" | tr -d '[A-Za-z=\"_]' > /tmp/zzz-tmp.log
    while read -a row ; do
        # if the last ARG of command `let` evaluates to 0, `let` returns 1
        let failures+=${row[0]} errors+=${row[1]} skipped+=${row[2]} tests+=${row[3]} || true
    done < /tmp/zzz-tmp.log
    TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
    cat > "${TEST_RESULT_FILE}" <<- EOF
cucushift:
  type: cucushift-logging
  total: $tests
  failures: $failures
  errors: $errors
  skipped: $skipped
EOF
    if [ $((failures)) != 0 ] ; then
        echo '  failingScenarios:' >> "${TEST_RESULT_FILE}"
        readarray -t failingscenarios < <(grep -h -r -E 'cucumber.*features/.*.feature' "${ARTIFACT_DIR}/.." | cut -d':' -f3- | sed -E 's/^( +)//;s/\x1b\[[0-9;]*m$//' | sort)
        for (( i=0; i<failures; i++ )) ; do
            echo "    - ${failingscenarios[$i]}" >> "${TEST_RESULT_FILE}"
        done
    fi
    cat "${TEST_RESULT_FILE}" | tee -a "${SHARED_DIR}/openshift-e2e-test-qe-report" || true
}

CUCUSHIFT_FORCE_SKIP_TAGS="not @customer
        and not @flaky
        and not @inactive
        and not @prod-only
        and not @qeci
        and not @security
        and not @stage-only
        and not @upgrade-check
        and not @upgrade-prepare
"
if [[ -z "$E2E_RUN_TAGS" ]] ; then
    echo "No need to run cucushift tests"
else
    export E2E_RUN_TAGS="$E2E_RUN_TAGS and $CUCUSHIFT_FORCE_SKIP_TAGS"
    set_cluster_access
    preparation_for_test
    test_execution
    summarize_test_results
fi
