#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cp -Lrvf "${KUBECONFIG}" /tmp/kubeconfig

#shellcheck source=${SHARED_DIR}/runtime_env
. .${SHARED_DIR}/runtime_env

cd verification-tests
# run normal tests
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/parallel-normal"
parallel_cucumber -n "${PARALLEL}" --first-is-1 --type cucumber --serialize-stdout --combine-stderr --prefix-output-with-test-env-number --exec \
    'export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=$(echo ${USERS} | cut -d "," -f ${TEST_ENV_NUMBER},$((${TEST_ENV_NUMBER}+${PARALLEL})),$((${TEST_ENV_NUMBER}+${PARALLEL}*2)));
     export WORKSPACE=/tmp/dir${TEST_ENV_NUMBER};
     parallel_cucumber --group-by found --only-group ${TEST_ENV_NUMBER} -o "--tags \"${E2E_RUN_LATEST_TAGS} and not @admin and not @serial and ${E2E_SKIP_TAGS}\" -p junit"' || true

# run admin tests
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/parallel-admin"
parallel_cucumber -n "${PARALLEL}" --first-is-1 --type cucumber --serialize-stdout --combine-stderr --prefix-output-with-test-env-number --exec \
    'export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=$(echo ${USERS} | cut -d "," -f ${TEST_ENV_NUMBER},$((${TEST_ENV_NUMBER}+${PARALLEL})),$((${TEST_ENV_NUMBER}+${PARALLEL}*2)));
     export WORKSPACE=/tmp/dir${TEST_ENV_NUMBER};
     parallel_cucumber --group-by found --only-group ${TEST_ENV_NUMBER} -o "--tags \"${E2E_RUN_LATEST_TAGS} and @admin and not @serial and ${E2E_SKIP_TAGS}\" -p junit"' || true

echo "Summarizing test result..."
failures=$(grep '<testsuite failures="[1-9].*"' "${ARTIFACT_DIR}" -r | wc -l || true)
if [ $((failures)) == 0 ]; then
    echo "All tests have passed"
else
    echo "${failures} failures in upgrade paused latest sanity tests" | tee -a "${SHARED_DIR}/upgrade_e2e_failures"
fi
