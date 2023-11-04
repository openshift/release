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
failures=0 errors=0 skipped=0 tests=0
grep -r -E -h -o 'testsuite.*tests="[0-9]+"' "${ARTIFACT_DIR}" | tr -d '[A-Za-z=\"_]' > /tmp/zzz-tmp.log
while read -a row ; do
    # if the last ARG of command `let` evaluates to 0, `let` returns 1
    let failures+=${row[0]} errors+=${row[1]} skipped+=${row[2]} tests+=${row[3]} || true
done < /tmp/zzz-tmp.log

TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results"
echo -e "\nfailures: $failures, errors: $errors, skipped: $skipped, tests: $tests in cucushift-e2e-ui" | tee -a "${TEST_RESULT_FILE}"
if [ $((failures)) != 0 ] ; then
    echo "Failing Scenarios:" | tee -a "${TEST_RESULT_FILE}"
    grep -h -r -E 'cucumber.*features/.*.feature' "${ARTIFACT_DIR}/.." | grep -v grep | cut -d'#' -f2 | sort -t':' -k3 | tee -a "${TEST_RESULT_FILE}" || true
fi
cat "${TEST_RESULT_FILE}" >> "${SHARED_DIR}/openshift-e2e-test-qe-report" || true
