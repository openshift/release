#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

FORCE_SKIP_TAGS="customer security"

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
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/ui"
export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS="${USERS}"
set -x
cucumber --tags "${E2E_RUN_TAGS} and ${E2E_SKIP_TAGS} and @console and not @destructive" -p junit || true
cucumber --tags "${E2E_RUN_TAGS} and ${E2E_SKIP_TAGS} and @console and @destructive" -p junit || true
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
    echo "${failures} failures in cucushift-e2e-ui" | tee -a "${SHARED_DIR}/cucushift-e2e-failures"
fi
