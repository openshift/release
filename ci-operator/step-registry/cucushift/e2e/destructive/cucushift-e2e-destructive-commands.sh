#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cp -Lrvf "${KUBECONFIG}" /tmp/kubeconfig

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
# run destructive tests in serial
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/destructive"
export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS="${USERS}"
cucumber --tags "${E2E_RUN_TAGS} and ${E2E_SKIP_TAGS}" -p junit || true

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
