#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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
if [ -z "${E2E_SKIP_TAGS}" ] ; then
    export E2E_SKIP_TAGS="not @customer and not @security"
else
    export E2E_SKIP_TAGS="${E2E_SKIP_TAGS} and not @customer and not @security"
fi

cd verification-tests
export BUSHSLICER_LOG_LEVEL=plain
# run normal tests
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/parallel/normal"
parallel_cucumber -n "${PARALLEL}" --first-is-1 --type cucumber --serialize-stdout --combine-stderr --prefix-output-with-test-env-number --exec \
    'export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=$(echo ${USERS} | cut -d "," -f ${TEST_ENV_NUMBER},$((${TEST_ENV_NUMBER}+${PARALLEL})),$((${TEST_ENV_NUMBER}+${PARALLEL}*2)),$((${TEST_ENV_NUMBER}+${PARALLEL}*3)));
     export WORKSPACE=/tmp/dir${TEST_ENV_NUMBER};
     parallel_cucumber --group-by found --only-group ${TEST_ENV_NUMBER} -o "--tags \"${E2E_RUN_TAGS} and not @admin and not @serial and ${E2E_SKIP_TAGS}\" -p junit"' || true

# run admin tests
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/parallel/admin"
parallel_cucumber -n "${PARALLEL}" --first-is-1 --type cucumber --serialize-stdout --combine-stderr --prefix-output-with-test-env-number --exec \
    'export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=$(echo ${USERS} | cut -d "," -f ${TEST_ENV_NUMBER},$((${TEST_ENV_NUMBER}+${PARALLEL})),$((${TEST_ENV_NUMBER}+${PARALLEL}*2)),$((${TEST_ENV_NUMBER}+${PARALLEL}*3)));
     export WORKSPACE=/tmp/dir${TEST_ENV_NUMBER};
     parallel_cucumber --group-by found --only-group ${TEST_ENV_NUMBER} -o "--tags \"${E2E_RUN_TAGS} and @admin and not @serial and ${E2E_SKIP_TAGS}\" -p junit"' || true

# run the rest tests in serial
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/serial"
export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS="${USERS}"
cucumber --tags "${E2E_RUN_TAGS} and @serial and ${E2E_SKIP_TAGS}" -p junit || true

# only exit 0 if junit result has no failures
echo "Summarizing test result..."
failures=$(grep '<testsuite failures="[1-9].*"' "${ARTIFACT_DIR}" -r | wc -l || true)
if [ $((failures)) == 0 ]; then
    echo "All tests have passed"
    exit 0
else
    echo "There are ${failures} test failures"
    exit 1
fi
