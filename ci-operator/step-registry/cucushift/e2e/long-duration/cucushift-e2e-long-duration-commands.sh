#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cp -Lrvf "${KUBECONFIG}" /tmp/kubeconfig

#shellcheck source=${SHARED_DIR}/runtime_env
. .${SHARED_DIR}/runtime_env

export E2E_RUN_TAGS="${E2E_RUN_TAGS} and ${TAG_VERSION}"
if [ -z "${E2E_SKIP_TAGS}" ] ; then
    export E2E_SKIP_TAGS="not @customer and not @security"
else
    export E2E_SKIP_TAGS="${E2E_SKIP_TAGS} and not @customer and not @security"
fi

cd verification-tests
# run long-duration tests in serial
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/long-duration"
export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS="${USERS}"
cucumber --tags "${E2E_RUN_TAGS} and ${E2E_SKIP_TAGS}" -p junit || true

# summarize test results
echo "Summarizing test result..."
failures=$(grep '<testsuite failures="[1-9].*"' "${ARTIFACT_DIR}" -r | wc -l || true)
if [ $((failures)) == 0 ]; then
    echo "All tests have passed"
else
    echo "${failures} failures in cucushift-e2e" | tee -a "${SHARED_DIR}/cucushift-e2e-failures"
fi
