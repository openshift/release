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

export E2E_RUN_TAGS="${E2E_RUN_TAGS} and ${TAG_VERSION}"
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
echo "Summarizing test result..."
mapfile -t test_suite_failures < <(grep -r -E 'testsuite.*failures="[1-9][0-9]*"' "${ARTIFACT_DIR}" | grep -o -E 'failures="[0-9]+"' | sed -E 's/failures="([0-9]+)"/\1/')
failures=0
for (( i=0; i<${#test_suite_failures[@]}; ++i ))
do
    let failures+=${test_suite_failures[$i]}
done
if [ $((failures)) == 0 ]; then
    echo "All tests have passed"
else
    echo "${failures} failures in cucushift-e2e" | tee -a "${SHARED_DIR}/openshift-e2e-test-qe-report-cucushift-failures"
fi
