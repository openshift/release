#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit
#
# CNV upgrade tests on the ACM spoke: runs pytest --upgrade cnv.
# Cluster and OLM prep is handled by the preceding
# interop-tests-openshift-virtualization-upgrade-prep step.
# CNV_TARGET_VERSION is read from ${SHARED_DIR}/cnv-target-version written by that step.
# CI Operator guarantees CNV_TARGET_VERSION env var (ref default) when the file is absent.
#

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    # Pinned to a reviewed commit SHA rather than refs/heads/main so this job does
    # not execute unreviewed upstream changes with its credentials.
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/2420b542141e9009f29ce02551244ebc43ed7060/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset -i startTime=${SECONDS}
typeset -r mergedJunitFN='junit--cnv__interop-tests__openshift-virtualization-upgrade-tests.xml'

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    # Pinned to a reviewed commit SHA (rather than refs/heads/main) to avoid
    # executing unreviewed upstream changes with the credentials of this job.
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/2420b542141e9009f29ce02551244ebc43ed7060/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
)"

# shellcheck disable=SC2329
# RunPostProcessPrep merges the jUnit XML under ARTIFACT_DIR, archives the originals,
# and copies the merged file to SHARED_DIR. When MAP_TESTS=true, the merged suite
# name is "<LP_IO__CR_COMP_PREFIX>--<original pytest suite>". %s is replaced with
# the suite name already in the jUnit file. The prefix defaults to
# lp-interop--CNV--ACM+Virt. The merge itself always runs.
# The library call is a plain statement, not `helper || rc=$?`. The helper ends with
# `true`, and a command on the left of `||` has errexit suppressed for its whole body,
# so a failed merge or copy would be reported as success. HandleExit turns errexit off
# around this call and records the status itself.
RunPostProcessPrep() {
    typeset newTsName=''
    typeset -i ppRC=0
    if [[ "${MAP_TESTS}" == 'true' ]]; then
        newTsName="${LP_IO__CR_COMP_PREFIX}--%s"
    fi
    LP_IO__ET_PPP__NEW_TS_NAME="${newTsName}" \
        ExitTrap--PostProcessPrep "${mergedJunitFN}"
    ppRC=$?
    return "${ppRC}"
}

# shellcheck disable=SC2329
# HandleExit is the EXIT trap. It is a function so the exit-code variables are real
# assignments. The same variables inside a single-quoted trap string are flagged
# SC2154, because shellcheck does not treat assignments in that string as assignments.
HandleExit() {
    typeset -i _exitCode=$?
    typeset -i _ppRC=0
    set +e
    RunPostProcessPrep
    _ppRC=$?
    set -e
    DebugOnExit "${_exitCode}" "${_ppRC}"
}

trap 'HandleExit' EXIT

# shellcheck disable=SC2329
# DebugOnExit — mainScriptEC is the script's own exit status. It is nonzero only for
# infrastructure failures before pytest. The main script exits 0 after pytest, and
# test failures stay in JUnit for Firewatch. postProcessEC is RunPostProcessPrep's
# result. An earlier script failure is kept, and it is the only path that enters the
# debug hold. A reporting failure on an otherwise successful script is the step's
# exit status, without the debug hold.
DebugOnExit() {
    typeset -i mainScriptEC="${1:?}"; (($#)) && shift
    typeset -i postProcessEC="${1:-0}"; (($#)) && shift
    typeset -i endTime=${SECONDS}
    typeset -i executionTime=$((endTime - startTime))
    typeset hcoNamespace="openshift-cnv"

    if (( mainScriptEC != 0 )); then
        : "SCRIPT EXITED PREMATURELY (runtime: ${executionTime}s, PID: $$, exitCode: ${mainScriptEC})"
        # Best-effort diagnostics on an already-failing step. || true is the allowed
        # diagnostic-artifact pattern; stderr is merged into the artifact.
        oc get -n "${hcoNamespace}" hco kubevirt-hyperconverged -o yaml \
            > "${ARTIFACT_DIR}"/hco-kubevirt-hyperconverged-cr.yaml 2>&1 || true
        oc logs --since=1h -n "${hcoNamespace}" -l name=hyperconverged-cluster-operator \
            > "${ARTIFACT_DIR}"/hco.log 2>&1 || true
        RunMustGather
        : "Entering debug hold (30 min max) — remove /tmp/debug_marker to exit early"
        touch /tmp/debug_marker
        typeset -i _debugDeadline=$(( ${SECONDS} + 1800 ))
        while [[ -f /tmp/debug_marker ]] && (( SECONDS < _debugDeadline )); do
            sleep 120
        done
        rm -f /tmp/debug_marker
    elif (( postProcessEC )); then
        : "Post-processing failed (rc=${postProcessEC}) though the script otherwise succeeded"
        mainScriptEC="${postProcessEC}"
    fi

    exit "${mainScriptEC}"
}

# Resolves the CNV must-gather image reference from the HCO CSV's relatedImages list
# (looked up by name containing "must-gather"). Prints the image pull spec, or nothing
# if the CSV/image entry can't be found — callers fall back to a version-pinned default.
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

# Runs `oc adm must-gather` with the CNV-specific gather script (--vms_details), using the
# image resolved by GetMustGatherImage, or a version-pinned fallback image when that lookup
# comes up empty (e.g. HCO CSV already gone). Output is collected under
# ${ARTIFACT_DIR}/must-gather-cnv for post-mortem debugging. || true is the allowed
# diagnostic-artifact pattern: this runs only after the step has already failed, and
# both streams are kept in the artifact instead of replacing DebugOnExit's exit code.
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
        -- /usr/bin/gather --vms_details > "${mustGatherCnvDir}"/must-gather-cnv.log 2>&1 || true
    true
}

# Downloads virtctl from the cluster's HyperConverged CLI-download route (derived from the
# ingress domain), extracts it into ${binFolder} (already on PATH), and verifies it runs via
# `virtctl version --client`. Exits the whole step non-zero on any failure, since a working
# virtctl is required for the upgrade test suite that runs afterward.
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

# Builds the pytest CLI argument list for the CNV upgrade run from CNV_* environment
# variables (target version/source/channel/storage-class-matrix) plus fixed data-collector
# and traceback options. Prints one argument per line. $1 is the installed CNV version.
# The caller redirects this in the current shell; a process substitution would hide a
# failure here from mapfile and let pytest start without these arguments.
# Appends --cnv-image only when CNV_TARGET_IMAGE is set.
BuildCnvUpgradePytestArgs() {
    typeset cnvVer="${1:?}"; (($#)) && shift
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
    # VirtualMachineTemplate (template.kubevirt.io) is part of CNV 4.22.
    # Pre-upgrade tests create VMs from that template before pytest upgrades CNV, so the
    # check uses the installed (source) version, not CNV_TARGET_VERSION:
    #   TestVMTemplatePreUpgrade::test_template_creation_before_upgrade
    #   TestVMTemplatePreUpgrade::test_vm_creation_from_template_before_upgrade
    typeset cnvMajor="${cnvVer%%.*}"
    typeset cnvRest="${cnvVer#*.}"
    typeset cnvMajorMinor="${cnvMajor}.${cnvRest%%.*}"
    if [[ "${cnvMajorMinor}" != "4.22" ]] \
        && [[ "$(printf '%s\n%s\n' "${cnvMajorMinor}" "4.22" | sort -V | head -n1)" == "${cnvMajorMinor}" ]]; then
        : "Installed CNV ${cnvVer} is below 4.22; ignoring tests/infrastructure/vm_template/"
        args+=(--ignore=tests/infrastructure/vm_template/)
    fi
    if [[ -n "${CNV_TARGET_IMAGE}" ]]; then
        args+=(--cnv-image "${CNV_TARGET_IMAGE}")
    fi
    printf '%s\n' "${args[@]}"
    true
}

# Runs the CNV upgrade pytest suite. $1 is the HCO subscription name. Remaining
# arguments are the pytest options, already checked by the caller. Only this pytest
# invocation is allowed to return non-zero: the caller records that status so a test
# failure does not skip later steps. Preparation must not be done here, because the
# caller invokes this function with `||` and that disables errexit for the whole body.
RunCnvUpgradePytest() {
    typeset hcoSubscription="${1:?}"; (($#)) && shift
    typeset -a cnvUpgradeArgs=("$@")
    typeset -i exitCode=0

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

typeset _wasTracing=''
[[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
set +x
# The artifactory user may fall back. The other four reads are required.
# Each required assignment is checked on its own: a `{ ...; export; } || rc=$?`
# group returns the status of export and hides an earlier head failure.
typeset -i _secretRc=0
ARTIFACTORY_USER=$(head -1 "${BW_PATH}"/artifactory-user || printf ci-read-only-user)
ARTIFACTORY_TOKEN=$(head -1 "${BW_PATH}"/artifactory-token) || _secretRc=$?
if (( _secretRc == 0 )); then
    ARTIFACTORY_SERVER=$(head -1 "${BW_PATH}"/artifactory-server) || _secretRc=$?
fi
if (( _secretRc == 0 )); then
    ACCESS_TOKEN=$(head -1 "${BW_PATH}"/bitwarden-client-secret) || _secretRc=$?
fi
if (( _secretRc == 0 )); then
    ORGANIZATION_ID=$(head -1 "${BW_PATH}"/bitwarden-org-id) || _secretRc=$?
fi
if [[ "${_wasTracing}" == "true" ]]; then
    set -x
fi
if (( _secretRc != 0 )); then
    exit "${_secretRc}"
fi
export ORGANIZATION_ID ACCESS_TOKEN ARTIFACTORY_USER ARTIFACTORY_TOKEN ARTIFACTORY_SERVER

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

# Preparation stays in this shell, where errexit is on. RunCnvUpgradePytest is invoked
# with `||`, which would ignore a failed lookup, a bad CSV name, or a partial argument
# list and still start pytest.
typeset installedCsv cnvSourceVer
installedCsv="$(oc get subscription.operators.coreos.com/hco-operatorhub -n openshift-cnv -o jsonpath='{.status.installedCSV}')"
[[ "${installedCsv}" == kubevirt-hyperconverged-operator.v* ]]
cnvSourceVer="${installedCsv#kubevirt-hyperconverged-operator.v}"
printf '%s\n' "${cnvSourceVer}" > "${ARTIFACT_DIR}/cnv-source-version"
typeset -a cnvUpgradeArgs=()
BuildCnvUpgradePytestArgs "${cnvSourceVer}" > "${ARTIFACT_DIR}/cnv-upgrade-pytest-args"
mapfile -t cnvUpgradeArgs < "${ARTIFACT_DIR}/cnv-upgrade-pytest-args"
(( ${#cnvUpgradeArgs[@]} > 0 ))
[[ "${cnvUpgradeArgs[0]}" == "--upgrade=cnv" ]]

# Record pytest's exit code without using it as the step exit code.
# Test failures are recorded in JUnit XML and picked up by Firewatch (FIREWATCH_FAIL_WITH_TEST_FAILURES=true).
# Exiting 0 here lets later test steps run. Preparation failures above are not caught
# by this `||` and still exit non-zero.
typeset -i exitCode=0

RunCnvUpgradePytest "${hcoSubscription}" "${cnvUpgradeArgs[@]}" || exitCode=$?

if (( exitCode != 0 )); then
    : "pytest exited ${exitCode} — test failures recorded in JUnit XML; step exits 0 to allow subsequent steps to run"
fi
exit 0
