#!/bin/bash
set -euo pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

set_proxy
run_command "oc config get-contexts"
run_command "oc version -o yaml"

k8sgpt version

AI_FLAGS=""
if [ -n "${AI_TOKEN_NAME}" ]; then
    ai_token=$(<"/var/run/vault/tests-private-account/${AI_TOKEN_NAME}")
    AI_FLAGS+=" -p ${ai_token}"
fi

if [ -n "${AI_MODE}" ]; then
    AI_FLAGS+=" -m ${AI_MODE}"
fi

if [ -n "${AI_BACKEND}" ]; then
    AI_FLAGS+=" -b ${AI_BACKEND}"
fi

EXTRA_FLAGS=""
if [ "${ENABLE_AI}" = "true" ]; then
    EXTRA_FLAGS+=" -aed"
    k8sgpt auth add ${AI_FLAGS} > "${ARTIFACT_DIR}/k8sgpt-result"
fi

if [ -n "${PROJECT}" ]; then
    EXTRA_FLAGS+=" -n ${PROJECT}"
fi

k8sgpt --kubeconfig=$KUBECONFIG analyze ${EXTRA_FLAGS} | tee -a "${ARTIFACT_DIR}/k8sgpt-result"


log=`cat ${ARTIFACT_DIR}/k8sgpt-result`

mkdir -p "${ARTIFACT_DIR}/junit"
if [[ ${log} =~ "No problems detected" ]]; then
    cat >"${ARTIFACT_DIR}/junit/k8sgpt-result.xml" <<EOF
    <testsuite name="api-job-k8sgpt" tests="1" failures="0">
        <testcase name="scanning cluster"/>
    </testsuite>
EOF
else
    cat >"${ARTIFACT_DIR}/junit/k8sgpt-result.xml" <<EOF
    <testsuite name="api-job-k8sgpt" tests="1" failures="1">
      <testcase name="scanning cluster">
        <failure message="">problems are detected</failure>
        <system-out>
          ${log}
        </system-out>
      </testcase>
    </testsuite>
EOF
fi
