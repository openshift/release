#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

PARALLEL_CUCUMBER_OPTIONS='--verbose-process-command --first-is-1 --type cucumber --serialize-stdout --combine-stderr --prefix-output-with-test-env-number'
FORCE_SKIP_TAGS="customer security"

function show_time_used() {
    local time_start test_type time_used
    time_start="$1"
    test_type="$2"

    time_used="$(( ($(date +%s) - time_start)/60 ))"
    echo "${test_type} tests took ${time_used} minutes"
}

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi
cp -Lrvf "${KUBECONFIG}" /tmp/kubeconfig

if ! which kubectl; then
    mkdir /tmp/bin
    export PATH=$PATH:/tmp/bin
    ln -s "$(which oc)" /tmp/bin/kubectl
fi

#shellcheck source=${SHARED_DIR}/runtime_env
source "${SHARED_DIR}/runtime_env"
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi
if [[ -n "$TAG_VERSION" ]] ; then
    export E2E_RUN_TAGS="${E2E_RUN_TAGS} and ${TAG_VERSION}"
fi
for tag in ${FORCE_SKIP_TAGS} ; do
    if ! [[ "${E2E_SKIP_TAGS}" =~ $tag ]] ; then
        export E2E_SKIP_TAGS="${E2E_SKIP_TAGS} and not $tag"
    fi
done
echo "E2E_RUN_TAGS is '${E2E_RUN_TAGS}'"
echo "E2E_SKIP_TAGS is '${E2E_SKIP_TAGS}'"

cd verification-tests
# run normal tests
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/parallel-normal"
timestamp_start="$(date +%s)"
parallel_cucumber -n "${PARALLEL}" ${PARALLEL_CUCUMBER_OPTIONS} --exec \
    'export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=$(echo ${USERS} | cut -d "," -f ${TEST_ENV_NUMBER},$((${TEST_ENV_NUMBER}+${PARALLEL})),$((${TEST_ENV_NUMBER}+${PARALLEL}*2)),$((${TEST_ENV_NUMBER}+${PARALLEL}*3)));
     export WORKSPACE=/tmp/dir${TEST_ENV_NUMBER};
     parallel_cucumber --group-by found --only-group ${TEST_ENV_NUMBER} -o "--tags \"${E2E_RUN_TAGS} and ${E2E_SKIP_TAGS} and not @serial and not @console and not @admin\" -p junit"' || true
show_time_used "$timestamp_start" 'normal'

# run admin tests
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/parallel-admin"
timestamp_start="$(date +%s)"
parallel_cucumber -n "${PARALLEL}" ${PARALLEL_CUCUMBER_OPTIONS} --exec \
    'export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=$(echo ${USERS} | cut -d "," -f ${TEST_ENV_NUMBER},$((${TEST_ENV_NUMBER}+${PARALLEL})),$((${TEST_ENV_NUMBER}+${PARALLEL}*2)),$((${TEST_ENV_NUMBER}+${PARALLEL}*3)));
     export WORKSPACE=/tmp/dir${TEST_ENV_NUMBER};
     parallel_cucumber --group-by found --only-group ${TEST_ENV_NUMBER} -o "--tags \"${E2E_RUN_TAGS} and ${E2E_SKIP_TAGS} and not @serial and not @console and @admin\" -p junit"' || true
show_time_used "$timestamp_start" 'admin'

# run the rest tests in serial
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/serial"
export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS="${USERS}"
timestamp_start="$(date +%s)"
set -x
cucumber --tags "${E2E_RUN_TAGS} and ${E2E_SKIP_TAGS} and ((@console and @smoke) or @serial)" -p junit || true
set +x
show_time_used "$timestamp_start" 'smoke console or serial'

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
  total: $tests
  failures: $failures
  errors: $errors
  skipped: $skipped
EOF

if [ $((failures)) != 0 ] ; then
    echo '  failingScenarios:' >> "${TEST_RESULT_FILE}"
    readarray -t failingscenarios < <(grep -h -r -E 'cucumber.*features/.*.feature' "${ARTIFACT_DIR}/.." | cut -d':' -f3- | sed -E 's/^( +)//' | sort)
    for (( i=0; i<failures; i++ )) ; do
        echo "    - ${failingscenarios[$i]}" >> "${TEST_RESULT_FILE}"
    done
fi
cat "${TEST_RESULT_FILE}" | tee -a "${SHARED_DIR}/openshift-e2e-test-qe-report" || true
