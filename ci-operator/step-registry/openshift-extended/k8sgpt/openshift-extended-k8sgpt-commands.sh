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

run_command "uname -m"
run_command "cat /etc/os-release"
set_proxy
run_command "oc config get-contexts"
run_command "oc version -o yaml"

OS="$(uname -s)_$(uname -m)"

K8SGPT_VERSION=${K8SGPT_VERSION:-0.4.25}
K8SGPT_DIR=${K8SGPT_DIR:-/tmp}

download_binary(){
  K8SPT_URL="https://github.com/k8sgpt-ai/k8sgpt/releases/download/v${K8SGPT_VERSION}/k8sgpt_${OS}.tar.gz"
  curl --fail --retry 8 --retry-all-errors -sS -L "${K8SPT_URL}" | tar -xzC "${K8SGPT_DIR}/"
}

rm -rf /tmp/k8sgpt
download_binary
${K8SGPT_DIR}/k8sgpt version

if [ -n "${OPTIONAL_FILTERS}" ]; then
    ${K8SGPT_DIR}/k8sgpt filters add ${OPTIONAL_FILTERS} > "${ARTIFACT_DIR}/k8sgpt-result"
fi

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
    ${K8SGPT_DIR}/k8sgpt auth add ${AI_FLAGS} | tee -a "${ARTIFACT_DIR}/k8sgpt-result"
fi

if [ -n "${PROJECT}" ]; then
    EXTRA_FLAGS+=" -n ${PROJECT}"
fi

${K8SGPT_DIR}/k8sgpt --kubeconfig=$KUBECONFIG analyze ${EXTRA_FLAGS} | tee -a "${ARTIFACT_DIR}/k8sgpt-result"


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
