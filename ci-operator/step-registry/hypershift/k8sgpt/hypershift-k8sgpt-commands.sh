#!/bin/bash

set -euo pipefail

EXPLAIN="${EXPLAIN:-false}"
JUNIT_REPORT="${JUNIT_REPORT:-false}"

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        # shellcheck disable=SC1091
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

set_proxy

k8sgpt version

explain_arg=""
if [[ "${EXPLAIN}" == "true" ]]; then
    explain_arg="--explain"
    openai_token=$(cat "/var/run/vault/tests-private-account/openai-token")
    k8sgpt auth add --model gpt-3.5-turbo --backend openai --password "${openai_token}" || true
fi

all_filters=(Ingress CronJob Node MutatingWebhookConfiguration Pod Deployment ReplicaSet \
ValidatingWebhookConfiguration ConfigMap PersistentVolumeClaim Service StatefulSet)
# Service and ValidatingWebhookConfiguration filters cause false negatives for hosted clusters.
# ConfigMap filters cause false positives, reporting unused configmaps.
excluded_filters=(Service ValidatingWebhookConfiguration ConfigMap)
active_filters=()
for filter in "${all_filters[@]}"; do
    if [[ ! ${excluded_filters[*]} =~ ${filter} ]]; then
        active_filters+=("$filter")
    fi
done

active_filters_str=$(echo "${active_filters[@]}" | tr ' ' ',')

common_params=(--output json --anonymize --with-doc "$explain_arg" --filter "$active_filters_str")

# Run the scan on the management cluster
k8sgpt --kubeconfig="$KUBECONFIG" analyze "${common_params[@]}" | \
    tee -a "${ARTIFACT_DIR}/k8sgpt-result-mgmt.json" || true

# Run the scan on the guest cluster
if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
    k8sgpt --kubeconfig="${SHARED_DIR}/nested_kubeconfig" analyze "${common_params[@]}" | \
        tee -a "${ARTIFACT_DIR}/k8sgpt-result-guest.json" || true
fi

# Optionally generate a JUnit report.
if [[ "${JUNIT_REPORT}" == "false" ]]; then
    exit 0
fi

result_mgmt=$(cat "${ARTIFACT_DIR}/k8sgpt-result-mgmt.json" || true)
result_guest=$(cat "${ARTIFACT_DIR}/k8sgpt-result-guest.json" || true)

mkdir -p "${ARTIFACT_DIR}/junit"

testcase_mgmt="<testcase name=\"scanning management cluster\"/>"
testcase_guest="<testcase name=\"scanning guest cluster\"/>"

np="No problems detected"

failures=0

if [[ ! ${result_mgmt} =~ $np ]]; then
    failures=$((failures + 1))
    testcase_mgmt=$(cat <<EOF
<testcase name="scanning management cluster">
    <failure message="">problems detected</failure>
    <system-out>
${result_mgmt}
    </system-out>
</testcase>
EOF
    )
fi

if [[ ! ${result_guest} =~ $np ]]; then
    failures=$((failures + 1))
    testcase_guest=$(cat <<EOF
<testcase name="scanning guest cluster">
    <failure message="">problems detected</failure>
    <system-out>
${result_guest}
    </system-out>
</testcase>
EOF
    )
fi

cat <<EOF >"${ARTIFACT_DIR}/junit/k8sgpt-result.xml"
<testsuite name="hypershift-k8sgpt" tests="2" failures="${failures}">
    ${testcase_mgmt}
    ${testcase_guest}
</testsuite>
EOF

