#!/bin/bash
#
# CNV upgrade tests on the ACM spoke: runs pytest --upgrade cnv.
# Cluster and OLM prep is handled by the preceding
# interop-tests-openshift-virtualization-upgrade-prep step.
# CNV_TARGET_VERSION is read from ${SHARED_DIR}/cnv-target-version written by that step.
# CI Operator guarantees CNV_TARGET_VERSION env var (ref default) when the file is absent.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    curl -fsSL https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset -i startTime=$SECONDS

trap 'DebugOnExit' EXIT

# shellcheck disable=SC2329
# DebugOnExit — only triggers on infrastructure failures (non-zero exit before pytest runs).
# pytest test failures (captured in JUnit XML) do NOT enter this path because the main
# script body always exits 0 after RunCnvUpgradePytest. The debug hold is only for cases
# where the step itself dies early (e.g. missing kubeconfig, virtctl install failure).
DebugOnExit() {
    typeset -i exitCode=$?
    typeset -i endTime=$SECONDS
    typeset -i executionTime=$((endTime - startTime))
    typeset hcoNamespace="openshift-cnv"

    if (( exitCode != 0 )); then
        : "SCRIPT EXITED PREMATURELY (runtime: ${executionTime}s, PID: $$, exitCode: ${exitCode})"
        oc get -n "${hcoNamespace}" hco kubevirt-hyperconverged -o yaml \
            > "${ARTIFACT_DIR}"/hco-kubevirt-hyperconverged-cr.yaml 2>/dev/null || true
        oc logs --since=1h -n "${hcoNamespace}" -l name=hyperconverged-cluster-operator \
            > "${ARTIFACT_DIR}"/hco.log 2>/dev/null || true
        RunMustGather
        : "Entering debug hold (30 min max) — remove /tmp/debug_marker to exit early"
        touch /tmp/debug_marker
        typeset -i _debugDeadline=$(( SECONDS + 1800 ))
        while [[ -f /tmp/debug_marker ]] && (( SECONDS < _debugDeadline )); do
            sleep 120
        done
        rm -f /tmp/debug_marker
    fi

    exit "${exitCode}"
}

# shellcheck disable=SC2329
GetMustGatherImage() {
    oc get csv --namespace='openshift-cnv' --selector='!olm.copiedFrom' --output='json' \
        | jq -r '
            .items[]
            | select(.metadata.name | contains("kubevirt-hyperconverged-operator"))
            | .spec.relatedImages[]
            | select(.name | contains("must-gather"))
            | .image'
    true
}

# shellcheck disable=SC2329
RunMustGather() {
    typeset image
    typeset fallbackImage="registry.redhat.io/container-native-virtualization/cnv-must-gather-rhel9:v${OCP_VERSION}"
    typeset mustGatherCnvDir="${ARTIFACT_DIR}/must-gather-cnv"

    image="$(GetMustGatherImage)"
    if [[ -z "${image}" ]]; then
        image="${fallbackImage}"
    fi

    mkdir -p "${mustGatherCnvDir}"
    oc adm must-gather --dest-dir="${mustGatherCnvDir}" --image="${image}" \
        -- /usr/bin/gather --vms_details | tee "${mustGatherCnvDir}"/must-gather-cnv.log || true
    true
}

MapTestsForComponentReadiness() {
    [[ "${MAP_TESTS}" != "true" ]] && return

    typeset resultsFile="${1:-}"
    : "Patching Tests Result File: ${resultsFile}"
    if [[ -f "${resultsFile}" ]]; then
        eval "$(
            curl -fsSL https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
        )"; EnsureReqs yq
        yq eval -px -ox -iI0 '.testsuites.testsuite.+@name="CNV-lp-interop"' "${resultsFile}"
    fi
    true
}

function InstallAndVerifyVirtctl () {
    typeset baseURL
    if ! baseURL="$(oc get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}' | tr -d '\n\r')"; then
        exit 1
    fi

    typeset dlURL="https://hyperconverged-cluster-cli-download-openshift-cnv.${baseURL}/amd64/linux/virtctl.tar.gz"
    if ! curl -kfsSL "${dlURL}" | tar -xzf - -C "${binFolder}"; then
        exit 1
    fi

    if [[ ! -x "${binFolder}/virtctl" ]]; then
        typeset virtctlPath
        virtctlPath="$(find "${binFolder}" -name virtctl -type f -executable | head -1)"
        if [[ -n "${virtctlPath}" ]]; then
            mv "${virtctlPath}" "${binFolder}/virtctl"
        fi
    fi

    if ! virtctl version --client; then
        exit 1
    fi
    true
}

BuildCnvUpgradePytestArgs() {
    typeset -a args=(
        --upgrade=cnv
        --cnv-version "${CNV_TARGET_VERSION}"
        --cnv-source "${CNV_SOURCE}"
        --cnv-channel "${CNV_CHANNEL}"
        --storage-class-matrix="${CNV_TARGET_STORAGE_CLASS}"
        --data-collector --data-collector-output-dir="${ARTIFACT_DIR}/"
        --ignore=tests/network/
        --tb=native
    )
    if [[ -n "${CNV_TARGET_IMAGE}" ]]; then
        args+=(--cnv-image "${CNV_TARGET_IMAGE}")
    fi
    printf '%s\n' "${args[@]}"
}

RunCnvUpgradePytest() {
    typeset hcoSubscription="${1:?}"; (($#)) && shift
    typeset -i exitCode=0
    typeset -a cnvUpgradeArgs=()
    mapfile -t cnvUpgradeArgs < <(BuildCnvUpgradePytestArgs)

    : "Single pytest run: full CNV upgrade suite with pre/post validation"
    uv --verbose --cache-dir /tmp/uv-cache \
        run pytest -o cache_dir=/tmp/pytest-cache \
        -s \
        -o log_cli=true \
        "${cnvUpgradeArgs[@]}" \
        --junitxml="${JUNIT_RESULTS_FILE}" \
        --pytest-log-file="${ARTIFACT_DIR}/tests.log" \
        --tc "hco_subscription:${hcoSubscription}" \
        || exitCode=$?

    return "${exitCode}"
}

# ── main ──────────────────────────────────────────────────────────────────────

typeset binFolder
binFolder="$(mktemp -d /tmp/bin.XXXX)"
typeset ocUrl="https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/latest/openshift-client-linux.tar.gz"

export PATH="${binFolder}:${PATH}"
export OPENSHIFT_PYTHON_WRAPPER_LOG_FILE="${ARTIFACT_DIR}/openshift_python_wrapper.log"
export JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_results.xml"
export HTML_RESULTS_FILE="${ARTIFACT_DIR}/report.html"

[[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
set +x
ARTIFACTORY_USER=$(head -1 "${BW_PATH}"/artifactory-user || printf ci-read-only-user)
ARTIFACTORY_TOKEN=$(head -1 "${BW_PATH}"/artifactory-token)
ARTIFACTORY_SERVER=$(head -1 "${BW_PATH}"/artifactory-server)
ACCESS_TOKEN=$(head -1 "${BW_PATH}"/bitwarden-client-secret)
ORGANIZATION_ID=$(head -1 "${BW_PATH}"/bitwarden-org-id)
export ORGANIZATION_ID ACCESS_TOKEN ARTIFACTORY_USER ARTIFACTORY_TOKEN ARTIFACTORY_SERVER
[[ "${_wasTracing}" == "true" ]] && set -x

unset KUBERNETES_SERVICE_PORT_HTTPS
unset KUBERNETES_SERVICE_PORT
unset KUBERNETES_PORT_443_TCP
unset KUBERNETES_PORT_443_TCP_PROTO
unset KUBERNETES_PORT_443_TCP_ADDR
unset KUBERNETES_SERVICE_HOST
unset KUBERNETES_PORT
unset KUBERNETES_PORT_443_TCP_PORT

curl -sL "${ocUrl}" | tar -C "${binFolder}" -xzf - oc

[ -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]
export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"

# Read CNV_TARGET_VERSION written by the prep step.
# CI Operator guarantees CNV_TARGET_VERSION is set (ref default) when the file is absent.
if [[ -f "${SHARED_DIR}/cnv-target-version" ]]; then
    CNV_TARGET_VERSION="$(< "${SHARED_DIR}/cnv-target-version")"
    export CNV_TARGET_VERSION
fi
: "CNV_TARGET_VERSION=${CNV_TARGET_VERSION}"

printf '%s\n' "${CNV_TARGET_VERSION}" > "${ARTIFACT_DIR}/cnv-target-version"

oc whoami --show-console
typeset -r hcoSubscriptionName="hco-operatorhub"
oc get "subscription.operators.coreos.com/${hcoSubscriptionName}" -n openshift-cnv
typeset hcoSubscription="${hcoSubscriptionName}"

: "CNV upgrade tests on spoke: target ${CNV_TARGET_VERSION} via ${CNV_SOURCE}/${CNV_CHANNEL}"

InstallAndVerifyVirtctl

# Run pytest and capture its exit code, but do NOT propagate it as the step exit code.
# Test failures are recorded in JUnit XML and picked up by Firewatch (FIREWATCH_FAIL_WITH_TEST_FAILURES=true).
# Exiting 0 here ensures subsequent test steps (e.g. ACM tests) always run regardless of
# individual pytest failures — the same pattern used by interop-tests-ocs-tests-commands.sh.
# Infrastructure failures (virtctl install, kubeconfig missing, etc.) still exit non-zero
# because they occur before this point and are not caught by this || true.
typeset -i exitCode=0

RunCnvUpgradePytest "${hcoSubscription}" || exitCode=$?

MapTestsForComponentReadiness "${JUNIT_RESULTS_FILE}"

if [[ -f "${JUNIT_RESULTS_FILE}" ]]; then
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}"
fi

if (( exitCode != 0 )); then
    : "pytest exited ${exitCode} — test failures recorded in JUnit XML; step exits 0 to allow subsequent steps to run"
fi
exit 0
