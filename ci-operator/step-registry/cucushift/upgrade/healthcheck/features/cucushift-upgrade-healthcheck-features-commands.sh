#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cp -Lrvf "${KUBECONFIG}" /tmp/kubeconfig

source "${SHARED_DIR}/runtime_env"

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/features"

cd verification-tests
cucumber -n "OCP-25436:ClusterInfrastructure Scale up and scale down a machineSet" || true

echo "Summarizing test result..."
failures=$(grep '<testsuite failures="[1-9].*"' "${ARTIFACT_DIR}" -r | wc -l || true)
if [ $((failures)) == 0 ]; then
    echo "All tests have passed"
else
    echo "${failures} failures in cucushift-e2e" | tee -a "${SHARED_DIR}/cucushift-e2e-failures"
fi