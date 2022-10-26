#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi
cp -Lrvf "${KUBECONFIG}" /tmp/kubeconfig

if [ -f "${SHARED_DIR}/runtime_env" ] ; then
    source "${SHARED_DIR}/runtime_env"
fi
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# configure cucushift runtime environment variables
hosts=$(grep server "${KUBECONFIG}" | cut -d '/' -f 3 | cut -d ':' -f 1)
ver_cli=$(oc version --client | cut -d ' ' -f 3 | cut -d '.' -f1,2)

runtime_env=${SHARED_DIR}/runtime_env

cat <<EOF >>"${runtime_env}"
export CUCUMBER_PUBLISH_QUIET=true
export DISABLE_WAIT_PRINT=true
export BUSHSLICER_DEFAULT_ENVIRONMENT=ocp4
export BUSHSLICER_LOG_LEVEL=INFO
export OPENSHIFT_ENV_OCP4_HOSTS="${hosts}:lb"
export OPENSHIFT_ENV_OCP4_ADMIN_CREDS_SPEC=file:///tmp/kubeconfig
export BUSHSLICER_CONFIG="{'global': {'browser': 'chrome'}, 'environments': {'ocp4': {'version': '${ver_cli}'}}}"
EOF
