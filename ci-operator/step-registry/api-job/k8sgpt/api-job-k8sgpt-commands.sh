#!/bin/bash

set -e
set -u
set -o pipefail

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

openai_token=$(cat "/var/run/vault/tests-private-account/openai-token")
k8sgpt version
k8sgpt auth add -m gpt-3.5-turbo -b openai -p ${openai_token} > ${ARTIFACT_DIR}/k8sgpt-result || true
k8sgpt --kubeconfig=$KUBECONFIG analyze -aed | tee -a ${ARTIFACT_DIR}/k8sgpt-result || true
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
