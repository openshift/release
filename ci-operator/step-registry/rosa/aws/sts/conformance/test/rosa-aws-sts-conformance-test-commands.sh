#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Grant image pull access for openshift-tests to extract test binaries from the payload
KUBECONFIG_BAK=$KUBECONFIG
unset KUBECONFIG
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}"
export KUBECONFIG=$KUBECONFIG_BAK

REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
ZONE="$(oc get -o jsonpath='{.items[0].metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}' nodes)"
export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true}"

if [[ -n "${TEST_SKIPS:-}" ]]; then
    # Strip whitespace around \| separators injected by YAML >- folding
    TEST_SKIPS=$(echo "$TEST_SKIPS" | sed 's/ *\\|/\\|/g; s/\\| */\\|/g')
    TESTS="$(openshift-tests run --dry-run --provider "${TEST_PROVIDER}" "${TEST_SUITE}")"
    echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests || { echo 'Error: all tests were filtered out by TEST_SKIPS regex:'; echo "$TEST_SKIPS"; exit 1; }
    echo "Skipping tests:"
    echo "${TESTS}" | grep "${TEST_SKIPS}" || true
    TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
fi

set +e
set -x
openshift-tests run "${TEST_SUITE}" ${TEST_ARGS:-} \
    --provider "${TEST_PROVIDER}" \
    -o "${ARTIFACT_DIR}/e2e.log" \
    --junit-dir "${ARTIFACT_DIR}/junit" 2>&1 | tee /tmp/openshift-tests.log

exit_code=${PIPESTATUS[0]}
set +x
set -e

if [[ "${SKIP_MONITOR_TEST:-}" == "true" ]] && [[ ${exit_code} -ne 0 ]]; then
    if grep -q 'failed due to a MonitorTest failure' /tmp/openshift-tests.log && \
       ! grep -q 'Blocking test failures:' /tmp/openshift-tests.log; then
        echo "Overriding MonitorTest-only failure (SKIP_MONITOR_TEST=true, no blocking test failures)"
        exit_code=0
    fi
fi

exit ${exit_code}
