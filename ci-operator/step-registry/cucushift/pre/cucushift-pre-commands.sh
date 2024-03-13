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
server="$(yq '.clusters[-1].cluster.server' "${KUBECONFIG}")"
IFS=':' read hosts api_port < <(echo ${server#*://})
ver_cli=$(oc version --client | grep -i client | cut -d ' ' -f 3 | cut -d '.' -f1,2)

runtime_env=${SHARED_DIR}/runtime_env
if [ -f "${runtime_env}" ] ; then
    if ! (grep -q 'CUCUMBER_PUBLISH_QUIET' "${runtime_env}") ; then
        cat <<EOF >> "${runtime_env}"
export CUCUMBER_PUBLISH_QUIET=true
EOF
    fi
    if ! (grep -q 'DISABLE_WAIT_PRINT' "${runtime_env}") ; then
        cat <<EOF >> "${runtime_env}"
export DISABLE_WAIT_PRINT=true
EOF
    fi
    if ! (grep -q 'BUSHSLICER_LOG_LEVEL' "${runtime_env}") ; then
        cat <<EOF >> "${runtime_env}"
export BUSHSLICER_LOG_LEVEL=INFO
EOF
    fi
    if ! (grep -q 'BUSHSLICER_DEFAULT_ENVIRONMENT' "${runtime_env}") ; then
        cat <<EOF >> "${runtime_env}"
export BUSHSLICER_DEFAULT_ENVIRONMENT=ocp4
export OPENSHIFT_ENV_OCP4_HOSTS="${hosts}:lb"
export OPENSHIFT_ENV_OCP4_ADMIN_CREDS_SPEC=file:///tmp/kubeconfig
EOF
    fi
    if ! (grep -q 'BUSHSLICER_CONFIG' "${runtime_env}") ; then
        cat <<EOF >> "${runtime_env}"
export BUSHSLICER_CONFIG="{'global': {'browser': 'chrome'}, 'environments': {'ocp4': {'api_port': '${api_port}', 'version': '${ver_cli}'}}}"
EOF
    fi
    cp "${runtime_env}" "${ARTIFACT_DIR}" || true
fi
