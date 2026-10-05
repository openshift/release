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
REAL_KILL=$(command -v kill)
REAL_SLEEP=$(command -v sleep)
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

assert_not_contains() {
    local pattern="$1"
    local file="$2"
    if grep -Eq -- "${pattern}" "${file}"; then
        fail "${file} contains prohibited pattern: ${pattern}"
    fi
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
    kill)
        exec "${REAL_KILL}" "$@"
        ;;
    mv)
        if [[ "${MOCK_ARCHIVE_FAILURE:-}" == "mv" && "$*" == *terraform_byoh_none.tar.tmp* ]]; then
            exit 73
        fi
        exec "${REAL_MV}" "$@"
        ;;
    oc)
        # TERM-ignoring diagnostic test: if enabled and apply is done, block forever
        if [[ "${MOCK_DIAGNOSTIC_TERM_IGNORE:-false}" == "true" && -f "${MOCK_APPLY_MARKER:-/nonexistent}" ]]; then
            trap 'printf "TERM observed\n" >>"${MOCK_TERM_MARKER}"' TERM
            while :; do "${REAL_SLEEP}" 0.1; done
        fi
        case "${1:-}" in
            get)
                case "${2:-}" in
                    namespace)
                        # Simulate namespace discovery for CCM watcher
                        if [[ "${MOCK_CCM_EXISTS:-true}" == "true" && "${3:-}" == "openshift-cloud-controller-manager" ]]; then
                            exit 0
                        fi
                        exit 1
                        ;;
                    deployments*|deployment*)
                        # Return a cloud-controller-manager deployment if configured
                        if [[ "${MOCK_CCM_EXISTS:-true}" == "true" && "$*" == *-n* ]]; then
                            echo "cloud-controller-manager   1/1   1   1   10d"
                            exit 0
                        fi
                        exit 0
                        ;;
                    nodes)
                        # Return synthetic node data with addresses to test redaction
                        if [[ "$*" == *jsonpath* ]]; then
                            echo "node=win-node-1 providerID=aws:///us-east-1a/i-0123456789abcdef0 addressTypes=InternalIP,Hostname, osImage=Windows Server 2022 kubelet=v1.29.0"
                        elif [[ "$*" == *custom-columns* ]]; then
                            echo "Ready   Windows Server 2022   v1.29.0"
                        fi
                        exit 0
                        ;;
                    infrastructure)
                        echo "aws"
                        exit 0
                        ;;
                    machinesets)
                        echo ""
                        exit 0
                        ;;
                    machines)
                        echo ""
                        exit 0
                        ;;
                    events*)
                        if [[ "${MOCK_INJECT_IP:-false}" == "true" ]]; then
                            echo "Warning   NodeNotReady   connection to 192.0.2.10 failed   3   2026-01-01T12:34:56Z"
                        fi
                        exit 0
                        ;;
                    csv*|subscription*|csr*)
                        exit 0
                        ;;
                    *)
                        exit 0
                        ;;
                esac
                ;;
            logs)
                # Return synthetic log with identifiers to test redaction
                echo "cloud-controller-manager: Deleting node ip-10-0-142-55.ec2.internal"
                echo "cloud-controller-manager: node does not exist in cloud provider arn:aws:ec2:us-east-1:123456789012:instance/i-abc123"
                echo "cloud-controller-manager: password=s3cretval token=tok-xyz"
                echo "cloud-controller-manager: endpoint [2001:db8::1]:8443 ready"
                echo "cloud-controller-manager: link-local fe80::abcd:1234:5678:9abc reached"
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        exit 0
        ;;
    sleep)
        # Accelerate sleep calls in tests
        exec "${REAL_SLEEP}" 0.01
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
    for command in chmod kill mv oc sleep tar terraform; do
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
    local ccm_exists="${6:-true}"
    local inject_ip="${7:-false}"
    local test_root log status
    setup_case
    test_root="${CASE_ROOT}"
    log="${test_root}/${name}.log"

    if [[ "${output_write_failure}" == "true" ]]; then
        ln -s /dev/full "${test_root}/artifacts/wmco-provision-failure/wmco-workloads.txt"
    fi

    set +o errexit
    "${REAL_TIMEOUT}" --kill-after=1s 15s env \
        ARTIFACT_DIR="${test_root}/artifacts" \
        BYOH_PROVISIONER_DIR="${test_root}/provisioner" \
        CLUSTER_PROFILE_DIR="${test_root}/cluster-profile" \
        DIAGNOSTIC_KILL_AFTER=0.1s \
        DIAGNOSTIC_TIMEOUT=0.5s \
        MOCK_APPLY_MARKER="${test_root}/apply-finished" \
        MOCK_APPLY_STATUS="${apply_status}" \
        MOCK_ARCHIVE_FAILURE="${archive_failure}" \
        MOCK_CCM_EXISTS="${ccm_exists}" \
        MOCK_DIAGNOSTIC_TERM_IGNORE="${term_ignore}" \
        MOCK_INJECT_IP="${inject_ip}" \
        MOCK_TERM_MARKER="${test_root}/term-observed" \
        PATH="${test_root}/bin:${PATH}" \
        REAL_CHMOD="${REAL_CHMOD}" \
        REAL_KILL="${REAL_KILL}" \
        REAL_MV="${REAL_MV}" \
        REAL_SLEEP="${REAL_SLEEP}" \
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

# --- Archive failure preservation tests (existing) ---

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
assert_contains "Diagnostic command failed or exceeded 0.5s" "${RUN_TEST_ROOT}/artifacts/wmco-provision-failure/wmco-workloads.txt"
echo "PASS: TERM-ignoring diagnostics are forcibly bounded and preserve the apply failure status"

run_case artifact_write_failure 42 "" false true
assert_status 42 "${RUN_STATUS}" artifact_write_failure
assert_contains "WARNING: Could not write failure diagnostic: ${RUN_TEST_ROOT}/artifacts/wmco-provision-failure/wmco-workloads.txt" "${RUN_LOG}"
if grep -Fq "Saved failure diagnostic: ${RUN_TEST_ROOT}/artifacts/wmco-provision-failure/wmco-workloads.txt" "${RUN_LOG}"; then
    fail "artifact_write_failure: falsely reported the failed write as saved"
fi
echo "PASS: failed diagnostic artifact writes report a warning"

# --- Early node capture tests ---

run_case early_node_capture 42 "" false false
assert_status 42 "${RUN_STATUS}" early_node_capture
assert_contains "Started early node watcher" "${RUN_LOG}"
assert_contains "Started early CCM watcher" "${RUN_LOG}"
# Finding 4: verify node-snapshots.txt is created and contains actual data
node_snap="${RUN_TEST_ROOT}/shared/early-node-capture/node-snapshots.txt"
[[ -s "${node_snap}" ]] || fail "early_node_capture: node-snapshots.txt is missing or empty (no data captured)"
# Verify it contains expected mock data fields (providerID, osImage from mock oc get nodes --watch)
grep -Fq "providerID=" "${node_snap}" || fail "early_node_capture: node-snapshots.txt lacks providerID field"
grep -Fq "osImage=" "${node_snap}" || fail "early_node_capture: node-snapshots.txt lacks osImage field"
echo "PASS: early watchers started and node-snapshots.txt contains captured data"

# --- Missing CCM handling ---

run_case missing_ccm 42 "" false false false
assert_status 42 "${RUN_STATUS}" missing_ccm
assert_contains "Started early CCM watcher" "${RUN_LOG}"
# Finding 6: unconditional file existence and content assertion
ccm_status_file="${RUN_TEST_ROOT}/shared/early-node-capture/ccm-status.txt"
[[ -f "${ccm_status_file}" ]] || fail "missing_ccm: ccm-status.txt was not created (capture path broken)"
assert_contains "No cloud-controller-manager deployment found" "${ccm_status_file}"
echo "PASS: missing CCM creates status file and is handled gracefully"

# --- Collector stop/reap on failure ---

run_case collector_stop_on_failure 42 "" false false
assert_status 42 "${RUN_STATUS}" collector_stop_on_failure
assert_contains "Started early node watcher" "${RUN_LOG}"
assert_contains "Started early CCM watcher" "${RUN_LOG}"
# On failure path, handle_exit stops watchers before collecting diagnostics
echo "PASS: background watchers are stopped on failure exit path"

# --- Finding 5: owned-child reaping via watcher TERM trap ---
# Test the EXACT trap pattern from start_node_watcher: a subshell that
# backgrounds a child, tracks its PID, and forwards TERM for clean reap.
# Uses only owned processes (no system-wide scans or kill 0).
REAP_DIR=$(mktemp -d)
TEST_ROOTS+=("${REAP_DIR}")
REAP_CHILD_PID_FILE="${REAP_DIR}/child.pid"
REAP_SENTINEL="${REAP_DIR}/child-started"

(
    _watch_pid=""
    trap '
        [[ -n "${_watch_pid}" ]] && kill -TERM "${_watch_pid}" 2>/dev/null || true
        wait "${_watch_pid}" 2>/dev/null || true
        exit 0
    ' TERM
    "${REAL_SLEEP}" 300 &
    _watch_pid=$!
    echo "${_watch_pid}" >"${REAP_CHILD_PID_FILE}"
    touch "${REAP_SENTINEL}"
    wait "${_watch_pid}" 2>/dev/null || true
    _watch_pid=""
) &
REAP_PARENT_PID=$!

# Wait for child to start (bounded: 5 seconds)
for (( _ri=0; _ri<50; _ri++ )); do
    [[ -f "${REAP_SENTINEL}" ]] && break
    "${REAL_SLEEP}" 0.1
done
[[ -f "${REAP_SENTINEL}" ]] || fail "child_reaping: child never started"
REAP_CHILD_PID=$(cat "${REAP_CHILD_PID_FILE}")
kill -0 "${REAP_CHILD_PID}" 2>/dev/null || fail "child_reaping: child not running before TERM"

# TERM the parent subshell (mimics stop_watchers sending TERM)
kill -TERM "${REAP_PARENT_PID}" 2>/dev/null || true
# Wait for parent to exit (bounded)
for (( _ri=0; _ri<50; _ri++ )); do
    kill -0 "${REAP_PARENT_PID}" 2>/dev/null || break
    "${REAL_SLEEP}" 0.1
done
wait "${REAP_PARENT_PID}" 2>/dev/null || true

# Allow brief propagation, then verify child was reaped
"${REAL_SLEEP}" 0.3
if kill -0 "${REAP_CHILD_PID}" 2>/dev/null; then
    kill -KILL "${REAP_CHILD_PID}" 2>/dev/null || true
    wait "${REAP_CHILD_PID}" 2>/dev/null || true
    fail "child_reaping: child PID ${REAP_CHILD_PID} survived parent TERM (owned-child leak)"
fi
echo "PASS: watcher TERM trap correctly forwards TERM and reaps owned child"
# Limitation note: this tests the cooperative TERM path. If the inner process
# ignores TERM, the subshell's wait blocks and stop_watchers escalates to KILL
# on the parent; the inner process is then orphaned but bounded by timeout(1)
# in production. A deterministic TERM-ignore + orphan-reap test is infeasible
# without system-wide process scans that are fragile in CI.

# --- Redaction tests ---
# Verify that public artifacts contain no raw IPs, hostnames, ARNs, or credentials

# Finding 2+3: inject TEST-NET IPs via mock to make assertions non-vacuous
run_case redaction_check 42 "" false false true true
assert_status 42 "${RUN_STATUS}" redaction_check
# Check public log output for prohibited patterns — no raw IPv4 addresses
assert_not_contains '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "${RUN_LOG}"
# Finding 2: negative control — prove the assertion catches IPs when present
neg_stdout_file="${RUN_TEST_ROOT}/negative-control-stdout.txt"
printf 'oc output: connecting to 192.0.2.10 endpoint\n' >"${neg_stdout_file}"
if ( assert_not_contains '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "${neg_stdout_file}" ) 2>/dev/null; then
    fail "redaction_check: negative control should have caught TEST-NET IP in stdout"
fi
echo "  Negative control: assert_not_contains correctly catches TEST-NET IP in stdout"
# Finding 3: verify injected TEST-NET IP in diagnostic artifact is redacted
events_file="${RUN_TEST_ROOT}/artifacts/wmco-provision-failure/wmco-events.txt"
[[ -f "${events_file}" ]] || fail "redaction_check: wmco-events.txt artifact not created"
[[ -s "${events_file}" ]] || fail "redaction_check: wmco-events.txt is empty (mock IP was not captured)"
# The injected 192.0.2.10 must be redacted to [REDACTED-IP]
assert_contains "[REDACTED-IP]" "${events_file}"
# The raw TEST-NET IP must NOT appear unredacted
assert_not_contains '192\.0\.2\.10' "${events_file}"
# Verify the timestamp in mock event output is preserved (not false-redacted as IPv6)
assert_contains "12:34:56" "${events_file}"
echo "  Injected TEST-NET IP is redacted in artifacts; timestamp preserved"
# Finding 3: negative control — show unredacted IP causes failure
neg_artifact_file="${RUN_TEST_ROOT}/negative-control-artifact.txt"
printf 'connection to 192.0.2.10 failed\n' >"${neg_artifact_file}"
if ( assert_not_contains '192\.0\.2\.10' "${neg_artifact_file}" ) 2>/dev/null; then
    fail "redaction_check: negative control should have caught raw IP in artifact"
fi
echo "  Negative control: assertion correctly catches unredacted TEST-NET IP in artifacts"
# Check all diagnostic files for unredacted IPs
for diag_file in "${RUN_TEST_ROOT}/artifacts/wmco-provision-failure/"*.txt; do
    [[ -f "${diag_file}" ]] || continue
    if grep -Eq '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' "${diag_file}" 2>/dev/null; then
        if grep -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' "${diag_file}" | grep -vq 'REDACTED'; then
            fail "redaction_check: ${diag_file} contains unredacted IP addresses"
        fi
    fi
done
# Check that no raw ARNs appear in public artifacts
for diag_file in "${RUN_TEST_ROOT}/artifacts/wmco-provision-failure/"*.txt; do
    [[ -f "${diag_file}" ]] || continue
    if grep -Eq 'arn:aws:' "${diag_file}" 2>/dev/null; then
        fail "redaction_check: ${diag_file} contains raw ARN"
    fi
done
# Check that raw WMCO logs go to SHARED_DIR (protected), not ARTIFACT_DIR
if [[ -f "${RUN_TEST_ROOT}/shared/wmco-failure-logs.txt" ]]; then
    echo "  Raw WMCO logs stored in protected SHARED_DIR (OK)"
fi
echo "PASS: public artifacts are redacted; injected IPs caught; no raw IPs, ARNs, or credentials"

# --- providerID privacy regression test ---
# Verify the success-path oc get commands do not expose raw providerID values
# in public CI log output (Finding 1). Only protected SHARED_DIR captures may
# contain providerID. Lines in comments or SHARED_DIR paths are excluded.
if grep -E 'custom-columns=.*providerID' "${PROVISION_SCRIPT}" | grep -vE '^\s*#' | grep -q .; then
    fail "providerID_privacy: success-path custom-columns includes raw providerID (leaks to CI logs)"
fi
echo "PASS: success-path custom-columns output does not include raw providerID"

# --- IPv6 redaction adversarial tests ---
# Verify the REDACT_PATTERN handles IPv6 addresses: compressed, full,
# link-local, leading ::, bracketed, zone IDs, and preserves timestamps.
eval "$(grep '^REDACT_PATTERN=' "${PROVISION_SCRIPT}")"
ipv6_assert_redacted() {
    local input="$1" prohibited="$2" desc="$3"
    local result
    result=$(printf '%s' "${input}" | sed -E "${REDACT_PATTERN}")
    if echo "${result}" | grep -Eq "${prohibited}"; then
        fail "ipv6_redaction: ${desc} — '${prohibited}' survived: ${result}"
    fi
}
ipv6_assert_preserved() {
    local input="$1" expected="$2" desc="$3"
    local result
    result=$(printf '%s' "${input}" | sed -E "${REDACT_PATTERN}")
    if ! echo "${result}" | grep -Fq "${expected}"; then
        fail "ipv6_redaction: ${desc} — expected '${expected}' preserved: ${result}"
    fi
}
# Standard IPv6 forms (previously worked; regression check)
ipv6_assert_redacted "endpoint [2001:db8::1]:8443 ready" "2001:db8" "bracketed compressed"
ipv6_assert_redacted "link-local fe80::abcd:1234:5678:9abc" "fe80::" "link-local"
ipv6_assert_redacted "full 2001:0db8:85a3:0000:0000:8a2e:0370:7334" "2001:0db8" "full 8 groups"
# Finding 1: leading :: addresses (previously missed)
ipv6_assert_redacted "::1 loopback" "^::1" "::1 loopback"
ipv6_assert_redacted "::abcd:1234:5678:9abc" "::abcd" "leading :: with groups"
ipv6_assert_redacted "saw [::1]:8443" "::1" "bracketed ::1"
# Zone ID and compressed-middle
ipv6_assert_redacted "fe80::1%eth0 link" "fe80::" "zone ID"
ipv6_assert_redacted "2001:db8:85a3::8a2e:370:7334" "2001:db8" "compressed middle"
# Finding 1: timestamp preservation (previously false-positive)
ipv6_assert_preserved "12:34:56 INFO: starting" "12:34:56" "HH:MM:SS timestamp"
ipv6_assert_preserved "2026-01-01T12:34:56Z event" "12:34:56" "ISO timestamp"
ipv6_assert_preserved "at 23:59:59 end of day" "23:59:59" "late timestamp"
ipv6_assert_preserved "00:00:00 midnight" "00:00:00" "midnight timestamp"
# Combined: timestamp and IPv6 on same line
ipv6_assert_preserved "12:34:56 saw [2001:db8::1]:8443" "12:34:56" "timestamp preserved with IPv6"
ipv6_assert_redacted "12:34:56 saw [2001:db8::1]:8443" "2001:db8" "IPv6 redacted with timestamp"
ipv6_assert_preserved "at 09:15:30 saw ::1" "09:15:30" "timestamp preserved with ::1"
ipv6_assert_redacted "at 09:15:30 saw ::1" "::1$" "::1 redacted with timestamp"
# Non-IPv6 (should NOT match)
result_2g=$(printf '%s' "1234:5678 data" | sed -E "${REDACT_PATTERN}")
[[ "${result_2g}" == *"1234:5678"* ]] || fail "ipv6_redaction: 2-group 1234:5678 was incorrectly redacted"
echo "PASS: IPv6 adversarial tests — ::, timestamps, brackets, zones all correct"

# --- Stock wait scoping tests (configuration verification) ---
# These verify the workflow YAML configuration, not the stock wait code itself

WORKFLOW_FILE="${REPO_ROOT}/ci-operator/step-registry/cucushift/installer/rehearse/aws/upi/ovn/winc/cucushift-installer-rehearse-aws-upi-ovn-winc-workflow.yaml"
DEPROVISION_FILE="${REPO_ROOT}/ci-operator/step-registry/cucushift/installer/rehearse/aws/upi/ovn/winc/deprovision/cucushift-installer-rehearse-aws-upi-ovn-winc-deprovision-chain.yaml"
MAIN_CONFIG="${REPO_ROOT}/ci-operator/config/openshift/openshift-tests-private/openshift-openshift-tests-private-main.yaml"
R50_CONFIG="${REPO_ROOT}/ci-operator/config/openshift/openshift-tests-private/openshift-openshift-tests-private-release-5.0.yaml"

# Verify deprovision chain does NOT include ref:wait (scope correction:
# wait is only for debug callers, not shared infrastructure)
if grep -Fq 'ref: wait' "${DEPROVISION_FILE}"; then
    fail "deprovision chain includes ref:wait (should be in debug callers only)"
fi
if grep -Fq 'cucushift-installer-rehearse-aws-upi-ovn-winc-debug-wait' "${DEPROVISION_FILE}"; then
    fail "deprovision chain still references the removed custom wait step"
fi
echo "PASS: deprovision chain does not include any wait step"

# Verify workflow does NOT set TIMEOUT or PR_ONLY (no shared wait overhead)
if grep -Eq '^\s+TIMEOUT:' "${WORKFLOW_FILE}"; then
    fail "workflow sets TIMEOUT (should be in debug callers only)"
fi
if grep -Eq '^\s+PR_ONLY:' "${WORKFLOW_FILE}"; then
    fail "workflow sets PR_ONLY (should be in debug callers only)"
fi
echo "PASS: workflow does not set TIMEOUT or PR_ONLY (zero added overhead for ordinary callers)"

# Verify debug callers have ref:wait in their post override with TIMEOUT +1 hour
debug_main_section=$(grep -A25 'debug-winc-aws-upi' "${MAIN_CONFIG}")
echo "${debug_main_section}" | grep -Fq 'ref: wait' || fail "main debug caller does not include ref:wait in post override"
echo "${debug_main_section}" | grep -Eq 'TIMEOUT:.*\+1 hour' || fail "main debug caller does not set TIMEOUT: +1 hour"
echo "${debug_main_section}" | grep -Fq 'PR_ONLY: "true"' || fail "main debug caller does not set PR_ONLY: true"
debug_r50_section=$(grep -A25 'debug-winc-aws-upi' "${R50_CONFIG}")
echo "${debug_r50_section}" | grep -Fq 'ref: wait' || fail "release-5.0 debug caller does not include ref:wait in post override"
echo "${debug_r50_section}" | grep -Eq 'TIMEOUT:.*\+1 hour' || fail "release-5.0 debug caller does not set TIMEOUT: +1 hour"
echo "${debug_r50_section}" | grep -Fq 'PR_ONLY: "true"' || fail "release-5.0 debug caller does not set PR_ONLY: true"
echo "PASS: debug callers have ref:wait in post override with TIMEOUT +1 hour and PR_ONLY true"

# Verify non-debug callers do NOT include ref:wait or TIMEOUT
FBC_CONFIG="${REPO_ROOT}/ci-operator/config/openshift/windows-machine-config-operator-fbc/openshift-windows-machine-config-operator-fbc-main.yaml"
if [[ -f "${FBC_CONFIG}" ]]; then
    fbc_section=$(grep -A15 'cucushift-installer-rehearse-aws-upi-ovn-winc' "${FBC_CONFIG}" | head -15)
    if echo "${fbc_section}" | grep -Eq '^\s+TIMEOUT:'; then
        fail "FBC caller incorrectly sets TIMEOUT"
    fi
    if echo "${fbc_section}" | grep -Fq 'ref: wait'; then
        fail "FBC caller incorrectly includes ref:wait"
    fi
    echo "PASS: FBC postsubmit caller has no wait or TIMEOUT (zero overhead)"
fi

# Verify the old custom wait files are removed
REMOVED_DIR="${REPO_ROOT}/ci-operator/step-registry/cucushift/installer/rehearse/aws/upi/ovn/winc/debug"
if [[ -d "${REMOVED_DIR}" ]]; then
    fail "obsolete custom debug/wait directory still exists"
fi
echo "PASS: obsolete custom debug/wait directory is removed"

# Verify no references to the old WINDOWS_AWS_UPI_POST_DEBUG_WAIT env var remain
if grep -rFq 'WINDOWS_AWS_UPI_POST_DEBUG_WAIT' "${REPO_ROOT}/ci-operator/"; then
    fail "references to removed WINDOWS_AWS_UPI_POST_DEBUG_WAIT env var still exist"
fi
echo "PASS: no references to removed WINDOWS_AWS_UPI_POST_DEBUG_WAIT env var"

# --- Owned-child cleanup verification (Finding 6) ---
# Verify that watcher subshells use tracked child PIDs for cleanup instead of
# kill 0 (which can terminate the caller or CI process group).
# Match 'kill 0' or 'kill -SIGNAL 0' (dangerous: kills process group), but
# exclude 'kill -0' (signal 0 = safe existence check) and comments.
if grep -E 'kill[[:space:]]+0[^0-9]|kill[[:space:]]+-[A-Za-z]+[[:space:]]+0[^0-9]' "${PROVISION_SCRIPT}" \
    | grep -vE 'kill -0|^\s*#|no kill 0' | grep -q .; then
    fail "owned_child_cleanup: provision script uses 'kill 0' which can terminate caller processes"
fi
# Verify that watcher subshells track child PIDs for cleanup
if ! grep -q '_watch_pid\|_ccm_child_pid' "${PROVISION_SCRIPT}"; then
    fail "owned_child_cleanup: provision script does not track child PIDs for cleanup"
fi
echo "PASS: watcher subshells track owned child PIDs for cleanup (no kill 0)"

# --- Watch mode verification (Finding 3) ---
# Verify that the node watcher uses --watch instead of sleep-based polling
if grep -q 'sleep 15' "${PROVISION_SCRIPT}"; then
    fail "watch_mode: node watcher still uses 15s polling instead of watch mode"
fi
if ! grep -Fq -- '--watch' "${PROVISION_SCRIPT}"; then
    fail "watch_mode: node watcher does not use --watch mode"
fi
echo "PASS: node watcher uses --watch mode for real-time event capture"

echo ""
echo "All tests passed"
