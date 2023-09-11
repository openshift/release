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
# run long duration tests in serial
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/longduration"
export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS="${USERS}"
set -x
cucumber --tags "${E2E_RUN_TAGS} and ${E2E_SKIP_TAGS} and @long-duration" -p junit || true
set +x

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
    echo "${failures} failures in cucushift-e2e" | tee -a "${SHARED_DIR}/cucushift-e2e-failures"
fi
