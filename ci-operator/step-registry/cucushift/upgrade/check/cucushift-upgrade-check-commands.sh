#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cp -Lrvf "${KUBECONFIG}" /tmp/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

#shellcheck source=${SHARED_DIR}/runtime_env
. .${SHARED_DIR}/runtime_env

upuser1=$(echo "${USERS}" | cut -d ',' -f 30)
upuser2=$(echo "${USERS}" | cut -d ',' -f 29)
export BUSHSLICER_CONFIG="
environments:
  ocp4:
    static_users_map:
      upuser1: '${upuser1}'
      upuser2: '${upuser2}'
"
export OPENSHIFT_ENV_OCP4_USER_MANAGER=UpgradeUserManager
export OPENSHIFT_ENV_OCP4_USER_MANAGER_USERS=${USERS}
export BUSHSLICER_REPORT_DIR="${ARTIFACT_DIR}/upgrade-check"
if [ -z "${UPGRADE_SKIP_TAGS}" ] ; then
    export UPGRADE_SKIP_TAGS="not @customer and not @security"
else
    export UPGRADE_SKIP_TAGS="${UPGRADE_SKIP_TAGS} and not @customer and not @security"
fi

cd verification-tests
set -x
cucumber --tags "${UPGRADE_CHECK_RUN_TAGS} and ${UPGRADE_SKIP_TAGS}" -p junit || true
set +x

echo "Summarizing test result..."
failures=$(grep '<testsuite failures="[1-9].*"' "${ARTIFACT_DIR}" -r | wc -l || true)
if [ $((failures)) == 0 ]; then
    echo "All tests have passed"
else
    echo "${failures} failures in upgrade check" | tee -a "${SHARED_DIR}/upgrade_e2e_failures"
fi
