#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROVISION_SCRIPT="${REPO_ROOT}/ci-operator/step-registry/windows/byoh/provision/windows-byoh-provision-commands.sh"
REAL_CHMOD=$(command -v chmod)
REAL_MV=$(command -v mv)
REAL_TAR=$(command -v tar)
REAL_TIMEOUT=$(command -v timeout)
TEST_ROOTS=()

cleanup() {
    local test_root
    for test_root in "${TEST_ROOTS[@]}"; do
        rm -rf "${test_root}"
    done
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local expected="$1"
    local file="$2"
    grep -Fq -- "${expected}" "${file}" || fail "${file} does not contain: ${expected}"
}

assert_status() {
    local expected="$1"
    local actual="$2"
    local name="$3"
    [[ "${actual}" -eq "${expected}" ]] || fail "${name}: expected status ${expected}, got ${actual}"
}

setup_case() {
    local test_root
    test_root=$(mktemp -d)
    TEST_ROOTS+=("${test_root}")
    mkdir -p "${test_root}/artifacts/wmco-provision-failure" \
        "${test_root}/bin" \
        "${test_root}/cluster-profile" \
        "${test_root}/provisioner" \
        "${test_root}/shared"
    printf 'ssh-rsa test-key\n' >"${test_root}/cluster-profile/ssh-publickey"

    cat >"${test_root}/bin/mock-command" <<'EOF'
#!/bin/bash
set -o nounset

case "$(basename -- "$0")" in
    chmod)
        if [[ "${MOCK_ARCHIVE_FAILURE:-}" == "chmod" && "$*" == *terraform_byoh_none.tar.tmp* ]]; then
            exit 72
        fi
        exec "${REAL_CHMOD}" "$@"
        ;;
    mv)
        if [[ "${MOCK_ARCHIVE_FAILURE:-}" == "mv" && "$*" == *terraform_byoh_none.tar.tmp* ]]; then
            exit 73
        fi
        exec "${REAL_MV}" "$@"
        ;;
    oc)
        if [[ "${MOCK_DIAGNOSTIC_TERM_IGNORE:-false}" == "true" && -f "${MOCK_APPLY_MARKER}" ]]; then
            trap 'printf "TERM observed\n" >>"${MOCK_TERM_MARKER}"' TERM
            while :; do :; done
        fi
        exit 0
        ;;
    tar)
        if [[ "${MOCK_ARCHIVE_FAILURE:-}" == "tar" && "$*" == *terraform_byoh_none.tar.tmp* ]]; then
            exit 71
        fi
        exec "${REAL_TAR}" "$@"
        ;;
    terraform)
        exit 0
        ;;
    *)
        echo "Unexpected mock invocation: $0" >&2
        exit 99
        ;;
esac
EOF
    chmod 755 "${test_root}/bin/mock-command"
    local command
    for command in chmod mv oc tar terraform; do
        ln -s mock-command "${test_root}/bin/${command}"
    done

    cat >"${test_root}/provisioner/byoh.sh" <<'EOF'
#!/bin/bash
set -o errexit
set -o nounset

mkdir -p "${BYOH_TMP_DIR}none"
printf 'partial terraform state\n' >"${BYOH_TMP_DIR}none/terraform.tfstate"
touch "${MOCK_APPLY_MARKER}"
exit "${MOCK_APPLY_STATUS}"
EOF
    chmod 755 "${test_root}/provisioner/byoh.sh"
    CASE_ROOT="${test_root}"
}

run_case() {
    local name="$1"
    local apply_status="$2"
    local archive_failure="$3"
    local term_ignore="$4"
    local output_write_failure="$5"
    local test_root log status
    setup_case
    test_root="${CASE_ROOT}"
    log="${test_root}/${name}.log"

    if [[ "${output_write_failure}" == "true" ]]; then
        ln -s /dev/full "${test_root}/artifacts/wmco-provision-failure/wmco-workloads.txt"
    fi

    set +o errexit
    "${REAL_TIMEOUT}" --kill-after=1s 8s env \
        ARTIFACT_DIR="${test_root}/artifacts" \
        BYOH_PROVISIONER_DIR="${test_root}/provisioner" \
        CLUSTER_PROFILE_DIR="${test_root}/cluster-profile" \
        DIAGNOSTIC_KILL_AFTER=0.1s \
        DIAGNOSTIC_TIMEOUT=0.1s \
        MOCK_APPLY_MARKER="${test_root}/apply-finished" \
        MOCK_APPLY_STATUS="${apply_status}" \
        MOCK_ARCHIVE_FAILURE="${archive_failure}" \
        MOCK_DIAGNOSTIC_TERM_IGNORE="${term_ignore}" \
        MOCK_TERM_MARKER="${test_root}/term-observed" \
        PATH="${test_root}/bin:${PATH}" \
        REAL_CHMOD="${REAL_CHMOD}" \
        REAL_MV="${REAL_MV}" \
        REAL_TAR="${REAL_TAR}" \
        SHARED_DIR="${test_root}/shared" \
        "${PROVISION_SCRIPT}" >"${log}" 2>&1
    status=$?
    set -o errexit

    [[ "${status}" -ne 124 && "${status}" -ne 137 ]] || fail "${name}: test exceeded its hard deadline"
    RUN_TEST_ROOT="${test_root}"
    RUN_LOG="${log}"
    RUN_STATUS="${status}"
}

run_case successful_publication 42 "" false false
assert_status 42 "${RUN_STATUS}" successful_publication
[[ -f "${RUN_TEST_ROOT}/shared/terraform_byoh_none.tar" ]] || fail "successful_publication: archive missing"
[[ ! -e "${RUN_TEST_ROOT}/shared/terraform_byoh_none.tar.tmp" ]] || fail "successful_publication: temporary archive remains"
"${REAL_TAR}" -tf "${RUN_TEST_ROOT}/shared/terraform_byoh_none.tar" | grep -Fq './terraform.tfstate' || fail "successful_publication: state missing from archive"
assert_contains "Returning original provisioning exit status 42" "${RUN_LOG}"
echo "PASS: successful archive publication preserves the apply failure status"

run_case tar_failure 42 tar false false
assert_status 42 "${RUN_STATUS}" tar_failure
[[ ! -e "${RUN_TEST_ROOT}/shared/terraform_byoh_none.tar" ]] || fail "tar_failure: archive was published"
[[ ! -e "${RUN_TEST_ROOT}/shared/terraform_byoh_none.tar.tmp" ]] || fail "tar_failure: temporary archive remains"
assert_contains "WARNING: Failed to save Terraform cleanup state for platform none" "${RUN_LOG}"
echo "PASS: tar failure is propagated and cleaned up"

run_case chmod_failure 0 chmod false false
assert_status 1 "${RUN_STATUS}" chmod_failure
[[ ! -e "${RUN_TEST_ROOT}/shared/terraform_byoh_none.tar" ]] || fail "chmod_failure: archive was published"
[[ ! -e "${RUN_TEST_ROOT}/shared/terraform_byoh_none.tar.tmp" ]] || fail "chmod_failure: temporary archive remains"
assert_contains "ERROR: BYOH provisioning succeeded but cleanup state could not be saved" "${RUN_LOG}"
echo "PASS: chmod failure prevents false-success provisioning"

run_case mv_failure 42 mv false false
assert_status 42 "${RUN_STATUS}" mv_failure
[[ ! -e "${RUN_TEST_ROOT}/shared/terraform_byoh_none.tar" ]] || fail "mv_failure: archive was published"
[[ ! -e "${RUN_TEST_ROOT}/shared/terraform_byoh_none.tar.tmp" ]] || fail "mv_failure: temporary archive remains"
assert_contains "Returning original provisioning exit status 42" "${RUN_LOG}"
echo "PASS: mv failure is cleaned up while preserving the apply failure status"

run_case term_ignoring_diagnostic 42 "" true false
assert_status 42 "${RUN_STATUS}" term_ignoring_diagnostic
[[ -s "${RUN_TEST_ROOT}/term-observed" ]] || fail "term_ignoring_diagnostic: TERM was not observed"
assert_contains "Diagnostic command failed or exceeded 0.1s" "${RUN_TEST_ROOT}/artifacts/wmco-provision-failure/wmco-workloads.txt"
echo "PASS: TERM-ignoring diagnostics are forcibly bounded and preserve the apply failure status"

run_case artifact_write_failure 42 "" false true
assert_status 42 "${RUN_STATUS}" artifact_write_failure
assert_contains "WARNING: Could not write failure diagnostic: ${RUN_TEST_ROOT}/artifacts/wmco-provision-failure/wmco-workloads.txt" "${RUN_LOG}"
if grep -Fq "Saved failure diagnostic: ${RUN_TEST_ROOT}/artifacts/wmco-provision-failure/wmco-workloads.txt" "${RUN_LOG}"; then
    fail "artifact_write_failure: falsely reported the failed write as saved"
fi
echo "PASS: failed diagnostic artifact writes report a warning"
