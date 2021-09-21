#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cp -Lrvf ${KUBECONFIG} /tmp/kubeconfig

#shellcheck source=${SHARED_DIR}/runtime_env
. .${SHARED_DIR}/runtime_env

export E2E_SKIP_TAGS="not @flaky and not @inactive and not @stage-only and not @proxy and not @disconnected and not @upgrade-prepare and not @upgrade-check and not @prow_unstable and not @destructive"
export PARALLEL=4

cd verification-tests
# run normal tests
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/parallel/normal"
parallel_cucumber -n ${PARALLEL} --first-is-1 --type cucumber --serialize-stdout --combine-stderr --prefix-output-with-test-env-number --exec \
    'export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=$(echo ${USERS} | cut -d "," -f ${TEST_ENV_NUMBER},$((${TEST_ENV_NUMBER}+${PARALLEL})),$((${TEST_ENV_NUMBER}+${PARALLEL}*2)));
     export WORKSPACE=/tmp/dir${TEST_ENV_NUMBER};
     parallel_cucumber --group-by found --only-group ${TEST_ENV_NUMBER} -o "--tags \"@aws-upi and not @admin and not @serial and ${E2E_SKIP_TAGS}\" -p junit"' || true

# run admin tests
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/parallel/admin"
parallel_cucumber -n ${PARALLEL} --first-is-1 --type cucumber --serialize-stdout --combine-stderr --prefix-output-with-test-env-number --exec \
    'export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=$(echo ${USERS} | cut -d "," -f ${TEST_ENV_NUMBER},$((${TEST_ENV_NUMBER}+${PARALLEL})),$((${TEST_ENV_NUMBER}+${PARALLEL}*2)));
     export WORKSPACE=/tmp/dir${TEST_ENV_NUMBER};
     parallel_cucumber --group-by found --only-group ${TEST_ENV_NUMBER} -o "--tags \"@aws-upi and @admin and not @serial and ${E2E_SKIP_TAGS}\" -p junit"' || true

# run the rest tests in serial
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/serial"
export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=${USERS}
cucumber --tags "@aws-upi and @serial and ${E2E_SKIP_TAGS}" -p junit || true

# only exit 0 if junit result has no failures
echo "Summarizing test result..."
failures=`grep '<testsuite failures="[1-9].*"' ${ARTIFACT_DIR} -r | wc -l || true`
if [ $((failures)) == 0 ]; then
    echo "All tests have passed"
    exit 0
else
    echo "There are ${failures} test failures"
    exit 1
fi
