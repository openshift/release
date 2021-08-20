#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Export those parameters before running
export BUSHSLICER_DEFAULT_ENVIRONMENT=ocp4
export BUSHSLICER_REPORT_DIR=${ARTIFACT_DIR}
export OPENSHIFT_ENV_OCP4_USER_MANAGER=UpgradeUserManager
export OPENSHIFT_ENV_OCP4_ADMIN_CREDS_SPEC=${KUBECONFIG}

hosts=`grep server ${KUBECONFIG} | cut -d '/' -f 3 | cut -d ':' -f 1`
export OPENSHIFT_ENV_OCP4_HOSTS="${hosts}:lb"

ver_cli=`oc version | grep Client | cut -d ' ' -f 3`
export BUSHSLICER_CONFIG="{'environments': {'ocp4': {'version': '${ver_cli:0:3}'}}}"

cd verification-tests
scl enable rh-ruby27 cucumber -p junit --tags "@upgrade-check"