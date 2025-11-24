#!/bin/bash

set -euo pipefail

EXPLAIN="${EXPLAIN:-false}"
JUNIT_REPORT="${JUNIT_REPORT:-false}"

OS="$(uname -s)_$(uname -m)"
K8SGPT_VERSION=${K8SGPT_VERSION:-0.4.25}
K8SGPT_DIR=${K8SGPT_DIR:-/tmp}

download_binary(){
  local url="https://github.com/k8sgpt-ai/k8sgpt/releases/download/v${K8SGPT_VERSION}/k8sgpt_${OS}.tar.gz"
  curl --fail --retry 8 --retry-all-errors -sS -L "${url}" | tar -xzC "${K8SGPT_DIR}/"
  chmod +x "${K8SGPT_DIR}/k8sgpt"
}

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

download_binary

export PATH="${K8SGPT_DIR}:${PATH}"

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

mkdir -p "${ARTIFACT_DIR}/namespaces" "${ARTIFACT_DIR}/hostedcluster"

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.namespace}' --ignore-not-found)

mgmt_namespaces=(hypershift)

if [[ -n "${HOSTED_CLUSTER_NS}" ]]; then
    mgmt_namespaces+=("${HOSTED_CLUSTER_NS}" "${HOSTED_CLUSTER_NS}-${CLUSTER_NAME}")
fi

echo "Collecting data from namespaces: ${mgmt_namespaces[*]}"

mgmt_fail=false
# Collect only hypershift-related namespaces from the management cluster.
for namespace in "${mgmt_namespaces[@]}"; do
    mkdir -p "${ARTIFACT_DIR}/namespaces/$namespace"
    # Run the scan on the management cluster
    result_file="${ARTIFACT_DIR}/namespaces/$namespace/result.json"
    k8sgpt --kubeconfig="$KUBECONFIG" analyze --namespace "$namespace" "${common_params[@]}" | \
        tee "$result_file" || true
    if [[ -f "$result_file" ]]; then
        if ! grep "problems\": 0" "$result_file" &>/dev/null; then
            mgmt_fail=true
        fi
    fi
done

guest_fail=false
# Run the scan on the guest cluster
if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
    k8sgpt --kubeconfig="${SHARED_DIR}/nested_kubeconfig" analyze "${common_params[@]}" | \
        tee "${ARTIFACT_DIR}/hostedcluster/result.json" || true
    if ! grep "problems\": 0" "${ARTIFACT_DIR}/hostedcluster/result.json" &>/dev/null; then
        guest_fail=true
    fi
fi

# Optionally generate a JUnit report.
if [[ "${JUNIT_REPORT}" == "false" ]]; then
    exit 0
fi

mkdir -p "${ARTIFACT_DIR}/junit"

testcase_mgmt="<testcase name=\"scanning management cluster\"/>"
testcase_guest="<testcase name=\"scanning guest cluster\"/>"

failures=0

if [[ "${mgmt_fail}" == "true" ]]; then
    failures=$((failures + 1))
    result_mgmt=""
    for namespace in "${mgmt_namespaces[@]}"; do
        result_mgmt+=$(cat "${ARTIFACT_DIR}/namespaces/$namespace/result.json")
    done
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

if [[ "${guest_fail}" == "true" ]]; then
    failures=$((failures + 1))
    result_guest=$(cat "${ARTIFACT_DIR}/hostedcluster/result.json")
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

