#!/bin/bash
set -o nounset
set -o pipefail

# Minimal environment smoke gate for sandboxed-containers-operator, run in the
# test phase. It runs a single openshift-tests-private (OTP) scenario selected by
# TEST_SMOKE_SCENARIOS (default sig-kata.*C00113, the operator installation case).
#
# Contract:
#   pass -> touch ${SHARED_DIR}/osc-post-smoke-ok ; exit 0
#   fail -> exit non-zero (test phase RED, job fails) ; no marker written
#
# The post-phase suites (full OTP, upstream-kata-bats) self-skip when the
# ${SHARED_DIR}/osc-post-smoke-ok marker is absent, so a failed pre/install or a
# failed smoke gate does not produce spurious suite failures.

MARKER="${SHARED_DIR}/osc-post-smoke-ok"

mkdir -p "${ARTIFACT_DIR}/junit"

write_skip_junit() {
    local msg="$1"
    cat > "${ARTIFACT_DIR}/junit/junit_smoke_gate_skipped.xml" <<EOF
<testsuite name="sandboxed-containers-operator-smoke-gate" tests="1" skipped="1">
  <testcase name="smoke-gate"><skipped message="${msg}"/></testcase>
</testsuite>
EOF
}

# When explicitly disabled, still let the post-phase suites run.
if [[ "${TEST_OPENSHIFT_EXTENDED_ENABLE:-}" == "false" ]]; then
    echo "TEST_OPENSHIFT_EXTENDED_ENABLE=false; skipping smoke gate and allowing post suites to run."
    write_skip_junit "TEST_OPENSHIFT_EXTENDED_ENABLE=false"
    touch "${MARKER}"
    exit 0
fi

export HOME=/tmp/home
export PATH=/usr/local/go/bin:/usr/libexec/origin:/opt/OpenShift4-tools:/usr/local/krew/bin:$PATH
mkdir -p "${HOME}"

# GITHUB_TOKEN is required by extended-platform-tests to enumerate cases.
if [[ -r "/var/run/vault/tests-private-account/token-git" ]]; then
    GITHUB_TOKEN=$(cat "/var/run/vault/tests-private-account/token-git")
    export GITHUB_TOKEN
fi

# link oc to kubectl if needed
if ! which kubectl >/dev/null 2>&1; then
    export PATH=$PATH:$HOME
    ln -s "$(which oc)" "${HOME}/kubectl" 2>/dev/null || true
fi

which extended-platform-tests

# setup proxy if present
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Wait for the cluster to be ready before running the smoke case.
oc version --client
oc wait nodes --all --for=condition=Ready=true --timeout=15m
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=15m || true

# Derive TEST_PROVIDER for the OSC platforms (azure IPI, ARO -> azure4; aws).
# Kept intentionally minimal; extend the case list if new platforms are added.
echo "CLUSTER_TYPE is ${CLUSTER_TYPE:-<unset>}"
case "${CLUSTER_TYPE:-}" in
azure4|azuremag|azure-arm64)
    export TEST_PROVIDER=azure
    ;;
azurestack)
    export TEST_PROVIDER="none"
    export AZURE_AUTH_LOCATION="${SHARED_DIR}/osServicePrincipal.json"
    ;;
aws)
    REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
    ZONE="$(oc get -o jsonpath='{.items[0].metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}' nodes)"
    export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true}"
    export KUBE_SSH_USER=core
    ;;
*)
    echo "No specific provider mapping for CLUSTER_TYPE='${CLUSTER_TYPE:-}'; using none."
    export TEST_PROVIDER="none"
    ;;
esac

mkdir -p /tmp/output
cd /tmp/output || exit 1

echo "TEST_SMOKE_SCENARIOS: \"${TEST_SMOKE_SCENARIOS}\""
echo "TEST_SMOKE_FILTERS:   \"${TEST_SMOKE_FILTERS:-}\""
echo "TEST_SMOKE_TIMEOUT:   \"${TEST_SMOKE_TIMEOUT}\" (minutes)"

# Select the smoke case(s).
extended-platform-tests run all --dry-run | grep -E "${TEST_SMOKE_SCENARIOS}" > ./case_selected || true

# Apply optional extra filters (simple AND-exclude/include on the case list).
if [[ -n "${TEST_SMOKE_FILTERS:-}" ]]; then
    IFS=";" read -r -a filters <<< "${TEST_SMOKE_FILTERS}"
    for filter in "${filters[@]}"; do
        [[ -z "${filter}" ]] && continue
        value="$(echo "${filter}" | grep -Eo '[a-zA-Z0-9_]{1,}')"
        if [[ "${filter}" == "~"* ]]; then
            grep -v -E "${value}" ./case_selected > ./case_selected.tmp || true
        else
            grep -E "${value}" ./case_selected > ./case_selected.tmp || true
        fi
        mv -f ./case_selected.tmp ./case_selected
    done
fi

selected_case_num=$(wc -l < ./case_selected)
echo "------ smoke case(s) selected: ${selected_case_num} ------"
cat ./case_selected
echo "----------------------------------------------------------"

if [[ "${selected_case_num}" -eq 0 ]]; then
    echo "ERROR: no smoke case matched TEST_SMOKE_SCENARIOS='${TEST_SMOKE_SCENARIOS}'."
    cat > "${ARTIFACT_DIR}/junit/junit_smoke_gate.xml" <<EOF
<testsuite name="sandboxed-containers-operator-smoke-gate" tests="1" failures="1">
  <testcase name="smoke-gate"><failure message="no case matched ${TEST_SMOKE_SCENARIOS}"/></testcase>
</testsuite>
EOF
    exit 1
fi

ret=0
if [[ "${TEST_PROVIDER}" == "none" ]]; then
    extended-platform-tests run --max-parallel-tests 1 \
        -o "${ARTIFACT_DIR}/smoke.log" \
        --timeout "${TEST_SMOKE_TIMEOUT}m" \
        --junit-dir "${ARTIFACT_DIR}/junit" \
        -f ./case_selected || ret=$?
else
    extended-platform-tests run --max-parallel-tests 1 \
        --provider "${TEST_PROVIDER}" \
        -o "${ARTIFACT_DIR}/smoke.log" \
        --timeout "${TEST_SMOKE_TIMEOUT}m" \
        --junit-dir "${ARTIFACT_DIR}/junit" \
        -f ./case_selected || ret=$?
fi

if [[ "${ret}" -eq 0 ]]; then
    echo "Smoke gate PASSED; writing marker ${MARKER} so post-phase suites run."
    touch "${MARKER}"
    exit 0
fi

echo "Smoke gate FAILED (rc=${ret}); NOT writing marker. Post-phase suites will self-skip."
exit "${ret}"
