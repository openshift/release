#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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
if [ -z "${E2E_SKIP_TAGS}" ] ; then
    export E2E_SKIP_TAGS="not @customer and not @security"
else
    export E2E_SKIP_TAGS="${E2E_SKIP_TAGS} and not @customer and not @security"
fi
echo "E2E_RUN_TAGS is '${E2E_RUN_TAGS}'"
echo "E2E_SKIP_TAGS is '${E2E_SKIP_TAGS}'"

cd verification-tests
# Run Logging tests
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/serial"
export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS="${USERS}"
export BUSHSLICER_CONFIG='
  environments:
    ocp4:
      logging_envs:
        clo:
          catsrc: "qe-app-registry"
          channel: "stable"
        eo:
          catsrc: "qe-app-registry"
          channel: "stable"'
timestamp_start="$(date +%s)"
set -x
cucumber --tags "${E2E_RUN_TAGS} and ${E2E_SKIP_TAGS} and (@console or @serial)" -p junit || true
set +x
show_time_used "$timestamp_start" 'console or serial'

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
    echo "${failures} failures in cucushift-logging-e2e" | tee -a "${SHARED_DIR}/cucushift-e2e-failures"
fi
