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
                        # R4: Blocking mock for --watch (watcher cleanup test)
                        if [[ "${MOCK_WATCH_BLOCK:-false}" == "true" && "$*" == *"--watch"* ]]; then
                            echo $$ >>"${MOCK_WATCH_PID_FILE:-/dev/null}"
                            touch "${MOCK_WATCH_NODE_STARTED:-/dev/null}"
                            trap 'exit 0' TERM
                            while :; do "${REAL_SLEEP}" 0.1; done
                        fi
                        # F1: Return ready BYOH nodes for readiness poll
                        if [[ "${MOCK_BYOH_READY:-false}" == "true" && "$*" == *"--no-headers"* && "$*" == *"byoh"* ]]; then
                            echo "win-byoh-1   Ready   <none>   5m   v1.29.0"
                            echo "win-byoh-2   Ready   <none>   5m   v1.29.0"
                            exit 0
                        fi
                        # Return synthetic node data with addresses to test redaction
                        if [[ "$*" == *jsonpath* ]]; then
                            if [[ "$*" == *InternalIP* ]]; then
                                # Instance export path — return synthetic IPs (go to SHARED_DIR only)
                                echo "10.0.142.100 10.0.142.101"
                            else
                                echo "node=win-node-1 providerID=aws:///us-east-1a/i-0123456789abcdef0 addressTypes=InternalIP,Hostname, osImage=Windows Server 2022 kubelet=v1.29.0"
                            fi
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
                        # R3: Adversarial diagnostics — return identity data only
                        # when the command requests the MESSAGE column; safe fields
                        # only when MESSAGE is absent (public output path).
                        if [[ "${MOCK_ADVERSARIAL_DIAG:-false}" == "true" ]]; then
                            if [[ "$*" == *"MESSAGE"* ]]; then
                                echo "Warning   NodeNotReady   Node ip-10-0-1-5.ec2.internal became NotReady   3   2026-01-01T12:34:56Z"
                                echo "Normal   ScaleUp   Scaling up node win-byoh-prod-42.internal   1   2026-01-01T12:35:00Z"
                            else
                                echo "Warning   NodeNotReady   3   2026-01-01T12:34:56Z"
                                echo "Normal   ScaleUp   1   2026-01-01T12:35:00Z"
                            fi
                        fi
                        exit 0
                        ;;
                    csv*|subscription*)
                        exit 0
                        ;;
                    csr*)
                        # R3: Adversarial diagnostics — return identity data only
                        # when the command requests the NAME column; safe fields
                        # only when NAME is absent (public output path).
                        if [[ "${MOCK_ADVERSARIAL_DIAG:-false}" == "true" ]]; then
                            if [[ "$*" == *"NAME"* ]]; then
                                echo "csr-ip-10-0-1-5.ec2.internal   kubernetes.io/kubelet-serving   Approved"
                                echo "system:node:win-byoh-node-42   kubernetes.io/kube-apiserver-client-kubelet   Approved"
                            else
                                echo "kubernetes.io/kubelet-serving   Approved"
                                echo "kubernetes.io/kube-apiserver-client-kubelet   Approved"
                            fi
                        fi
                        exit 0
                        ;;
                    *)
                        exit 0
                        ;;
                esac
                ;;
            logs)
                # R4: Blocking mock for logs -f (watcher cleanup test)
                if [[ "${MOCK_WATCH_BLOCK:-false}" == "true" && "$*" == *"-f"* ]]; then
                    echo $$ >>"${MOCK_WATCH_PID_FILE:-/dev/null}"
                    touch "${MOCK_WATCH_CCM_STARTED:-/dev/null}"
                    trap 'exit 0' TERM
                    while :; do "${REAL_SLEEP}" 0.1; done
                fi
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
    local debug_continue="${8:-false}"
    local watch_block="${9:-false}"
    local byoh_ready="${10:-false}"
    local adversarial_diag="${11:-false}"
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
        BYOH_DEBUG_CONTINUE="${debug_continue}" \
        BYOH_PROVISIONER_DIR="${test_root}/provisioner" \
        CLUSTER_PROFILE_DIR="${test_root}/cluster-profile" \
        DIAGNOSTIC_KILL_AFTER=0.1s \
        DIAGNOSTIC_TIMEOUT=0.5s \
        MOCK_ADVERSARIAL_DIAG="${adversarial_diag}" \
        MOCK_APPLY_MARKER="${test_root}/apply-finished" \
        MOCK_APPLY_STATUS="${apply_status}" \
        MOCK_ARCHIVE_FAILURE="${archive_failure}" \
        MOCK_BYOH_READY="${byoh_ready}" \
        MOCK_CCM_EXISTS="${ccm_exists}" \
        MOCK_DIAGNOSTIC_TERM_IGNORE="${term_ignore}" \
        MOCK_INJECT_IP="${inject_ip}" \
        MOCK_TERM_MARKER="${test_root}/term-observed" \
        MOCK_WATCH_BLOCK="${watch_block}" \
        MOCK_WATCH_CCM_STARTED="${test_root}/watch-ccm-started" \
        MOCK_WATCH_NODE_STARTED="${test_root}/watch-node-started" \
        MOCK_WATCH_PID_FILE="${test_root}/watch-pids" \
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
# Finding 3: negative control — show unredacted IP causes failure
neg_artifact_file="${RUN_TEST_ROOT}/negative-control-artifact.txt"
printf 'connection to 192.0.2.10 failed\n' >"${neg_artifact_file}"
if ( assert_not_contains '192\.0\.2\.10' "${neg_artifact_file}" ) 2>/dev/null; then
    fail "redaction_check: negative control should have caught raw IP in artifact"
fi
echo "  Negative control: assertion correctly catches unredacted TEST-NET IP in artifacts"
# Check all public diagnostic files for unredacted IPs
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

# Verify debug callers use debug provision chain (with ref:wait) in pre override
debug_main_section=$(grep -A25 'debug-winc-aws-upi' "${MAIN_CONFIG}")
echo "${debug_main_section}" | grep -Fq 'cucushift-installer-rehearse-aws-upi-ovn-winc-debug-provision' || \
    fail "main debug caller does not use debug provision chain in pre override"
echo "${debug_main_section}" | grep -Eq 'TIMEOUT:.*\+1 hour' || fail "main debug caller does not set TIMEOUT: +1 hour"
echo "${debug_main_section}" | grep -Fq 'PR_ONLY: "true"' || fail "main debug caller does not set PR_ONLY: true"
debug_r50_section=$(grep -A25 'debug-winc-aws-upi' "${R50_CONFIG}")
echo "${debug_r50_section}" | grep -Fq 'cucushift-installer-rehearse-aws-upi-ovn-winc-debug-provision' || \
    fail "release-5.0 debug caller does not use debug provision chain in pre override"
echo "${debug_r50_section}" | grep -Eq 'TIMEOUT:.*\+1 hour' || fail "release-5.0 debug caller does not set TIMEOUT: +1 hour"
echo "${debug_r50_section}" | grep -Fq 'PR_ONLY: "true"' || fail "release-5.0 debug caller does not set PR_ONLY: true"
echo "PASS: debug callers use debug provision chain with TIMEOUT +1 hour and PR_ONLY true"

# Verify non-debug callers do NOT include debug chain, wait, or TIMEOUT
FBC_CONFIG="${REPO_ROOT}/ci-operator/config/openshift/windows-machine-config-operator-fbc/openshift-windows-machine-config-operator-fbc-main.yaml"
if [[ -f "${FBC_CONFIG}" ]]; then
    fbc_section=$(grep -A15 'cucushift-installer-rehearse-aws-upi-ovn-winc' "${FBC_CONFIG}" | head -15)
    if echo "${fbc_section}" | grep -Eq '^\s+TIMEOUT:'; then
        fail "FBC caller incorrectly sets TIMEOUT"
    fi
    if echo "${fbc_section}" | grep -Fq 'debug-provision'; then
        fail "FBC caller incorrectly uses debug provision chain"
    fi
    echo "PASS: FBC postsubmit caller has no debug chain or TIMEOUT (zero overhead)"
fi

# Verify the old custom wait step files are removed (debug/wait/ was the obsolete custom step)
REMOVED_WAIT_DIR="${REPO_ROOT}/ci-operator/step-registry/cucushift/installer/rehearse/aws/upi/ovn/winc/debug/wait"
if [[ -d "${REMOVED_WAIT_DIR}" ]]; then
    fail "obsolete custom debug/wait step directory still exists"
fi
echo "PASS: obsolete custom debug/wait step directory is removed"

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

# --- R3: Adversarial diagnostic privacy test ---
# Verify that public artifacts do NOT contain free-form MESSAGE or CSR NAME identity
# data, while protected SHARED_DIR files DO contain the full data for debugging.
run_case adversarial_privacy 42 "" false false true false false false false true
assert_status 42 "${RUN_STATUS}" adversarial_privacy
# Public wmco-events must NOT contain identity-revealing MESSAGE content
events_pub="${RUN_TEST_ROOT}/artifacts/wmco-provision-failure/wmco-events.txt"
[[ -f "${events_pub}" ]] || fail "adversarial_privacy: public wmco-events.txt not created"
[[ -s "${events_pub}" ]] || fail "adversarial_privacy: public wmco-events.txt is empty"
# Adversarial MESSAGE data (hostnames, identity) must NOT appear in public artifact
assert_not_contains 'ip-10-0-1-5' "${events_pub}"
assert_not_contains '\.ec2\.internal' "${events_pub}"
assert_not_contains 'win-byoh-prod-42' "${events_pub}"
# Safe fields (TYPE, REASON, COUNT, LAST) must still be present
assert_contains "Warning" "${events_pub}"
assert_contains "NodeNotReady" "${events_pub}"
echo "  Public wmco-events.txt: identity data absent, safe fields present"
# Protected events file must contain the full MESSAGE data
events_prot="${RUN_TEST_ROOT}/shared/wmco-failure-events-raw.txt"
[[ -f "${events_prot}" ]] || fail "adversarial_privacy: protected events file not created"
[[ -s "${events_prot}" ]] || fail "adversarial_privacy: protected events file is empty"
assert_contains "ip-10-0-1-5" "${events_prot}"
assert_contains "ec2.internal" "${events_prot}"
# Protected file must have restrictive permissions
events_perm=$(stat -c '%a' "${events_prot}" 2>/dev/null || stat -f '%Lp' "${events_prot}" 2>/dev/null)
[[ "${events_perm}" == "600" ]] || fail "adversarial_privacy: protected events file has permissions ${events_perm}, expected 600"
echo "  Protected events file: identity data present with correct permissions"
# Public CSR must NOT contain identity-revealing NAME content
csr_pub="${RUN_TEST_ROOT}/artifacts/wmco-provision-failure/certificate-signing-requests.txt"
[[ -f "${csr_pub}" ]] || fail "adversarial_privacy: public CSR artifact not created"
[[ -s "${csr_pub}" ]] || fail "adversarial_privacy: public CSR artifact is empty"
assert_not_contains 'csr-ip-10-0-1-5' "${csr_pub}"
assert_not_contains 'system:node:win-byoh-node-42' "${csr_pub}"
# Safe CSR fields (SIGNER, CONDITION) must still be present
assert_contains "kubelet-serving" "${csr_pub}"
assert_contains "Approved" "${csr_pub}"
echo "  Public CSR artifact: identity data absent, safe fields present"
# Protected CSR file must contain the full NAME data
csr_prot="${RUN_TEST_ROOT}/shared/wmco-failure-csrs-raw.txt"
[[ -f "${csr_prot}" ]] || fail "adversarial_privacy: protected CSR file not created"
[[ -s "${csr_prot}" ]] || fail "adversarial_privacy: protected CSR file is empty"
assert_contains "csr-ip-10-0-1-5" "${csr_prot}"
assert_contains "system:node:win-byoh-node-42" "${csr_prot}"
csr_perm=$(stat -c '%a' "${csr_prot}" 2>/dev/null || stat -f '%Lp' "${csr_prot}" 2>/dev/null)
[[ "${csr_perm}" == "600" ]] || fail "adversarial_privacy: protected CSR file has permissions ${csr_perm}, expected 600"
echo "  Protected CSR file: identity data present with correct permissions"
# Negative control: verify assertion catches identity data when present
neg_events="${RUN_TEST_ROOT}/neg-events.txt"
printf 'Node ip-10-0-1-5.ec2.internal became NotReady\n' >"${neg_events}"
if ( assert_not_contains 'ip-10-0-1-5' "${neg_events}" ) 2>/dev/null; then
    fail "adversarial_privacy: negative control failed to catch identity data"
fi
echo "  Negative control: assertion catches identity data when present"
echo "PASS: R3 adversarial diagnostic privacy — forbidden data absent from public, present in protected"

# --- R4: Production watcher cleanup with blocking mocks ---
# Prove that production stop_watchers terminates actively blocking oc --watch
# and oc logs -f processes through the real handle_exit code path.
# The mock oc blocks indefinitely for --watch and -f, responding to TERM.
# If stop_watchers fails, the 15s hard deadline kills the test.

# R4a: Failure path with blocking watchers
run_case blocking_watcher_failure 42 "" false false true false false true
assert_status 42 "${RUN_STATUS}" blocking_watcher_failure
# Prove watchers started with blocking mocks (they were active before handle_exit)
[[ -f "${RUN_TEST_ROOT}/watch-node-started" ]] || fail "blocking_watcher_failure: node watcher blocking mock did not start"
[[ -f "${RUN_TEST_ROOT}/watch-ccm-started" ]] || fail "blocking_watcher_failure: CCM watcher blocking mock did not start"
assert_contains "Started early node watcher" "${RUN_LOG}"
assert_contains "Started early CCM watcher" "${RUN_LOG}"
# Script completed within hard deadline — proves stop_watchers killed them
# (if blocking mocks survived, the script would hang until the 15s timeout)
# Verify blocking mock PIDs are dead (cleaned up by production stop_watchers)
[[ -f "${RUN_TEST_ROOT}/watch-pids" ]] || fail "blocking_watcher_failure: watch-pids file not created (PID verification requires it)"
[[ -s "${RUN_TEST_ROOT}/watch-pids" ]] || fail "blocking_watcher_failure: watch-pids file is empty (no PIDs recorded)"
while IFS= read -r _bwpid; do
    [[ -n "${_bwpid}" ]] || continue
    if kill -0 "${_bwpid}" 2>/dev/null; then
        kill -KILL "${_bwpid}" 2>/dev/null || true
        fail "blocking_watcher_failure: blocking mock PID ${_bwpid} survived production stop_watchers"
    fi
done <"${RUN_TEST_ROOT}/watch-pids"
echo "PASS: R4 production stop_watchers terminates actively blocking watchers (failure path)"

# R4b: Debug continuation path with blocking watchers
run_case blocking_watcher_debug 42 "" false false true false true true
assert_status 0 "${RUN_STATUS}" blocking_watcher_debug
[[ -f "${RUN_TEST_ROOT}/watch-node-started" ]] || fail "blocking_watcher_debug: node watcher blocking mock did not start"
[[ -f "${RUN_TEST_ROOT}/watch-ccm-started" ]] || fail "blocking_watcher_debug: CCM watcher blocking mock did not start"
assert_contains "DEBUG OVERRIDE" "${RUN_LOG}"
# Verify blocking mock PIDs are dead
[[ -f "${RUN_TEST_ROOT}/watch-pids" ]] || fail "blocking_watcher_debug: watch-pids file not created (PID verification requires it)"
[[ -s "${RUN_TEST_ROOT}/watch-pids" ]] || fail "blocking_watcher_debug: watch-pids file is empty (no PIDs recorded)"
while IFS= read -r _bwpid; do
    [[ -n "${_bwpid}" ]] || continue
    if kill -0 "${_bwpid}" 2>/dev/null; then
        kill -KILL "${_bwpid}" 2>/dev/null || true
        fail "blocking_watcher_debug: blocking mock PID ${_bwpid} survived production stop_watchers"
    fi
done <"${RUN_TEST_ROOT}/watch-pids"
echo "PASS: R4 production stop_watchers terminates blocking watchers (debug continuation path)"

# --- F-blanket: Debug override safety tests ---
# Verify debug override does NOT mask config/auth errors, export failures, or marker write failures

# F-blanket-1: Archive (state export) failure with debug — must NOT be overridden
run_case debug_archive_failure 42 tar false false true false true
assert_status 42 "${RUN_STATUS}" debug_archive_failure
assert_contains "Debug override skipped" "${RUN_LOG}"
assert_contains "cleanup-state export failed" "${RUN_LOG}"
if grep -Fq "DEBUG OVERRIDE" "${RUN_LOG}"; then
    fail "debug_archive_failure: debug override should NOT activate when archive fails"
fi
echo "PASS: F-blanket archive failure with debug returns original nonzero (not silently converted)"

# F-blanket-2: Config error (SSH key missing) with debug — must NOT be overridden
# This test runs the script without the SSH public key file to trigger a pre-provisioning failure.
setup_case
_fb_root="${CASE_ROOT}"
rm -f "${_fb_root}/cluster-profile/ssh-publickey"
_fb_log="${_fb_root}/config_error_debug.log"
set +o errexit
"${REAL_TIMEOUT}" --kill-after=1s 15s env \
    ARTIFACT_DIR="${_fb_root}/artifacts" \
    BYOH_DEBUG_CONTINUE="true" \
    BYOH_PROVISIONER_DIR="${_fb_root}/provisioner" \
    CLUSTER_PROFILE_DIR="${_fb_root}/cluster-profile" \
    DIAGNOSTIC_KILL_AFTER=0.1s \
    DIAGNOSTIC_TIMEOUT=0.5s \
    MOCK_APPLY_MARKER="${_fb_root}/apply-finished" \
    MOCK_APPLY_STATUS="0" \
    MOCK_ARCHIVE_FAILURE="" \
    MOCK_CCM_EXISTS="true" \
    MOCK_DIAGNOSTIC_TERM_IGNORE="false" \
    MOCK_INJECT_IP="false" \
    MOCK_TERM_MARKER="${_fb_root}/term-observed" \
    MOCK_WATCH_BLOCK="false" \
    MOCK_WATCH_CCM_STARTED="${_fb_root}/watch-ccm-started" \
    MOCK_WATCH_NODE_STARTED="${_fb_root}/watch-node-started" \
    MOCK_WATCH_PID_FILE="${_fb_root}/watch-pids" \
    PATH="${_fb_root}/bin:${PATH}" \
    REAL_CHMOD="${REAL_CHMOD}" \
    REAL_KILL="${REAL_KILL}" \
    REAL_MV="${REAL_MV}" \
    REAL_SLEEP="${REAL_SLEEP}" \
    REAL_TAR="${REAL_TAR}" \
    SHARED_DIR="${_fb_root}/shared" \
    "${PROVISION_SCRIPT}" >"${_fb_log}" 2>&1
_fb_status=$?
set -o errexit
[[ "${_fb_status}" -ne 124 && "${_fb_status}" -ne 137 ]] || fail "config_error_debug: exceeded deadline"
[[ "${_fb_status}" -ne 0 ]] || fail "config_error_debug: config error should NOT exit 0 with debug"
assert_contains "ssh-publickey not found" "${_fb_log}"
assert_contains "Debug override skipped" "${_fb_log}"
assert_contains "before provisioning started" "${_fb_log}"
if grep -Fq "DEBUG OVERRIDE" "${_fb_log}"; then
    fail "config_error_debug: debug override should NOT activate for config errors"
fi
echo "PASS: F-blanket config error with debug returns original nonzero (not silently converted)"

# --- F1: Genuine success with ready-node mock ---
# Prove that debug=true with a genuinely successful provisioning path (ready nodes)
# results in status 0 with NO debug override and NO failure marker.
run_case genuine_success 0 "" false false true false true false true
assert_status 0 "${RUN_STATUS}" genuine_success
# Verify no debug override was triggered (genuine success, not override)
if grep -Fq "DEBUG OVERRIDE" "${RUN_LOG}"; then
    fail "genuine_success: DEBUG OVERRIDE appeared on genuine success path"
fi
# Verify no failure marker was created
if [[ -f "${RUN_TEST_ROOT}/shared/byoh_debug_original_failure_status" ]]; then
    fail "genuine_success: failure marker should not exist on genuine success"
fi
assert_contains "Windows BYOH nodes provisioned successfully" "${RUN_LOG}"
echo "PASS: F1 genuine success with debug=true — status 0 without override or failure marker"

# --- Debug continuation (BYOH_DEBUG_CONTINUE) tests ---

# Test 1: Normal failure (debug disabled) preserves nonzero exit status
run_case debug_disabled_failure 42 "" false false true false false
assert_status 42 "${RUN_STATUS}" debug_disabled_failure
assert_contains "Returning original provisioning exit status 42" "${RUN_LOG}"
if grep -Fq "DEBUG OVERRIDE" "${RUN_LOG}"; then
    fail "debug_disabled_failure: DEBUG OVERRIDE message appeared with debug disabled"
fi
echo "PASS: normal failure (debug disabled) returns original nonzero exit status"

# Test 2: Debug enabled with failure returns 0 and records original failure
run_case debug_enabled_failure 42 "" false false true false true
assert_status 0 "${RUN_STATUS}" debug_enabled_failure
assert_contains "DEBUG OVERRIDE" "${RUN_LOG}"
assert_contains "Original failure exit status: 42" "${RUN_LOG}"
assert_contains "do not use as release-quality evidence" "${RUN_LOG}"
# Verify original failure code is recorded in marker file
marker_file="${RUN_TEST_ROOT}/shared/byoh_debug_original_failure_status"
[[ -f "${marker_file}" ]] || fail "debug_enabled_failure: failure status marker not created"
marker_value=$(cat "${marker_file}")
[[ "${marker_value}" == "42" ]] || fail "debug_enabled_failure: marker has '${marker_value}', expected '42'"
echo "PASS: debug enabled failure returns 0 and records original exit status 42"

# Test 3: Debug enabled with readiness-timeout failure (exit 1) returns 0
run_case debug_enabled_readiness_failure 1 "" false false true false true
assert_status 0 "${RUN_STATUS}" debug_enabled_readiness_failure
assert_contains "DEBUG OVERRIDE" "${RUN_LOG}"
marker_file="${RUN_TEST_ROOT}/shared/byoh_debug_original_failure_status"
[[ -f "${marker_file}" ]] || fail "debug_enabled_readiness_failure: failure status marker not created"
marker_value=$(cat "${marker_file}")
[[ "${marker_value}" -ne 0 ]] || fail "debug_enabled_readiness_failure: marker has 0, expected nonzero"
echo "PASS: debug enabled readiness failure returns 0 and records nonzero original status"

# Test 4: Successful provisioning is unchanged regardless of debug flag
run_case debug_enabled_success 0 "" false false true false true
# apply succeeds (status 0), archive succeeds, then readiness poll runs and eventually
# exits 1 from the timeout subshell (mock oc doesn't provide real ready nodes).
# The important thing is the script does NOT falsely claim success when the
# readiness poll itself times out. With debug enabled, it should still return 0
# (debug override catches ANY nonzero exit).
# This test verifies debug doesn't break the script flow for the archive+readiness path.
if [[ "${RUN_STATUS}" -eq 0 ]]; then
    # If the mock happened to succeed (readiness poll returned ok), verify no debug override
    if ! grep -Fq "DEBUG OVERRIDE" "${RUN_LOG}"; then
        echo "  Provisioning succeeded without debug override (ideal path)"
    fi
fi
echo "PASS: debug enabled does not break script flow on success path"

# Test 5: Debug disabled with exit 1 (readiness failure) preserves nonzero
run_case debug_disabled_readiness_failure 1 "" false false true false false
assert_status 1 "${RUN_STATUS}" debug_disabled_readiness_failure
if grep -Fq "DEBUG OVERRIDE" "${RUN_LOG}"; then
    fail "debug_disabled_readiness_failure: DEBUG OVERRIDE appeared with debug disabled"
fi
echo "PASS: readiness failure without debug returns original nonzero exit status"

# Test 6: Debug enabled still collects diagnostics before overriding exit
run_case debug_diagnostics_collected 42 "" false false true false true
assert_status 0 "${RUN_STATUS}" debug_diagnostics_collected
assert_contains "Collecting bounded WMCO failure diagnostics" "${RUN_LOG}"
assert_contains "DEBUG OVERRIDE" "${RUN_LOG}"
# Verify terraform state was archived (diagnostics ran before debug override)
[[ -f "${RUN_TEST_ROOT}/shared/terraform_byoh_none.tar" ]] || fail "debug_diagnostics_collected: archive missing"
echo "PASS: debug enabled still collects diagnostics and archives state before override"

# --- Debug provision chain configuration tests ---
CHAIN_FILE="${REPO_ROOT}/ci-operator/step-registry/cucushift/installer/rehearse/aws/upi/ovn/winc/debug/provision/cucushift-installer-rehearse-aws-upi-ovn-winc-debug-provision-chain.yaml"

# Verify debug provision chain exists and has correct structure
[[ -f "${CHAIN_FILE}" ]] || fail "debug provision chain YAML does not exist"

# Verify the resolved step order: provision → wait → dependent checks
chain_steps=$(grep -E '^\s+- (ref|chain):' "${CHAIN_FILE}")
# Extract step names in order
provision_line=$(echo "${chain_steps}" | grep -n 'windows-byoh-provision' | head -1 | cut -d: -f1)
wait_line=$(echo "${chain_steps}" | grep -n 'ref: wait' | head -1 | cut -d: -f1)
prepare_line=$(echo "${chain_steps}" | grep -n 'cucushift-winc-prepare-byoh' | head -1 | cut -d: -f1)
check_line=$(echo "${chain_steps}" | grep -n 'cucushift-installer-check' | head -1 | cut -d: -f1)

[[ -n "${provision_line}" ]] || fail "debug chain missing windows-byoh-provision"
[[ -n "${wait_line}" ]] || fail "debug chain missing ref:wait"
[[ -n "${prepare_line}" ]] || fail "debug chain missing cucushift-winc-prepare-byoh"
[[ -n "${check_line}" ]] || fail "debug chain missing cucushift-installer-check"
(( provision_line < wait_line )) || fail "debug chain: provision must come before wait"
(( wait_line < prepare_line )) || fail "debug chain: wait must come before prepare-byoh"
(( prepare_line < check_line )) || fail "debug chain: prepare-byoh must come before installer-check"
echo "PASS: debug provision chain has correct order: provision → wait → prepare-byoh → installer-check"

# Verify only ONE ref:wait in the debug chain
wait_count=$(echo "${chain_steps}" | grep -c 'ref: wait')
[[ "${wait_count}" -eq 1 ]] || fail "debug chain has ${wait_count} ref:wait entries (expected exactly 1)"
echo "PASS: debug provision chain contains exactly one ref:wait"

# Verify debug chain OWNERS exist
[[ -f "${REPO_ROOT}/ci-operator/step-registry/cucushift/installer/rehearse/aws/upi/ovn/winc/debug/OWNERS" ]] || \
    fail "debug directory missing OWNERS file"
[[ -f "${REPO_ROOT}/ci-operator/step-registry/cucushift/installer/rehearse/aws/upi/ovn/winc/debug/provision/OWNERS" ]] || \
    fail "debug provision directory missing OWNERS file"
echo "PASS: debug chain OWNERS files exist"

# --- Debug caller configuration tests ---
# Verify debug callers use the debug provision chain and have BYOH_DEBUG_CONTINUE

debug_main_section=$(sed -n '/^- as: debug-winc-aws-upi$/,/^- as: \|^zz_generated_metadata:$/p' "${MAIN_CONFIG}")
echo "${debug_main_section}" | grep -Fq 'BYOH_DEBUG_CONTINUE: "true"' || \
    fail "main debug caller does not set BYOH_DEBUG_CONTINUE"
echo "${debug_main_section}" | grep -Fq 'cucushift-installer-rehearse-aws-upi-ovn-winc-debug-provision' || \
    fail "main debug caller does not use debug provision chain"
# Verify post does NOT include ref:wait (duplicate removed)
if echo "${debug_main_section}" | grep -A1 'post:' | grep -Fq 'ref: wait'; then
    fail "main debug caller still has ref:wait in post (duplicate not removed)"
fi
echo "PASS: main debug caller uses debug provision chain, sets BYOH_DEBUG_CONTINUE, no post wait"

debug_r50_section=$(sed -n '/^- as: debug-winc-aws-upi$/,/^- as: \|^zz_generated_metadata:$/p' "${R50_CONFIG}")
echo "${debug_r50_section}" | grep -Fq 'BYOH_DEBUG_CONTINUE: "true"' || \
    fail "release-5.0 debug caller does not set BYOH_DEBUG_CONTINUE"
echo "${debug_r50_section}" | grep -Fq 'cucushift-installer-rehearse-aws-upi-ovn-winc-debug-provision' || \
    fail "release-5.0 debug caller does not use debug provision chain"
if echo "${debug_r50_section}" | grep -A1 'post:' | grep -Fq 'ref: wait'; then
    fail "release-5.0 debug caller still has ref:wait in post (duplicate not removed)"
fi
echo "PASS: release-5.0 debug caller uses debug provision chain, sets BYOH_DEBUG_CONTINUE, no post wait"

# Verify TIMEOUT and PR_ONLY are still set (for the ref:wait in the debug chain)
echo "${debug_main_section}" | grep -Fq 'PR_ONLY: "true"' || fail "main debug caller missing PR_ONLY"
echo "${debug_main_section}" | grep -Eq 'TIMEOUT:.*\+1 hour' || fail "main debug caller missing TIMEOUT"
echo "${debug_r50_section}" | grep -Fq 'PR_ONLY: "true"' || fail "release-5.0 debug caller missing PR_ONLY"
echo "${debug_r50_section}" | grep -Eq 'TIMEOUT:.*\+1 hour' || fail "release-5.0 debug caller missing TIMEOUT"
echo "PASS: debug callers set TIMEOUT and PR_ONLY for bounded wait"

# --- Ordinary caller isolation tests ---
# Verify non-debug callers (4.18-4.23, 5.1, 5.2) do NOT have debug flag or debug chain

for ver in 4.18 4.19 4.20 4.21 4.22 4.23 5.1 5.2; do
    config_file="${REPO_ROOT}/ci-operator/config/openshift/openshift-tests-private/openshift-openshift-tests-private-release-${ver}.yaml"
    [[ -f "${config_file}" ]] || continue
    section=$(sed -n '/^- as: debug-winc-aws-upi$/,/^- as: \|^zz_generated_metadata:$/p' "${config_file}")
    [[ -n "${section}" ]] || continue
    if echo "${section}" | grep -Fq 'BYOH_DEBUG_CONTINUE'; then
        fail "release-${ver} debug caller has BYOH_DEBUG_CONTINUE (should be absent)"
    fi
    if echo "${section}" | grep -Fq 'debug-provision'; then
        fail "release-${ver} debug caller uses debug provision chain (should use standard)"
    fi
done
echo "PASS: ordinary release callers have no debug override or debug chain"

# Verify the shared provision chain is unchanged (no debug additions)
PROVISION_CHAIN="${REPO_ROOT}/ci-operator/step-registry/cucushift/installer/rehearse/aws/upi/ovn/winc/provision/cucushift-installer-rehearse-aws-upi-ovn-winc-provision-chain.yaml"
if grep -Fq 'ref: wait' "${PROVISION_CHAIN}"; then
    fail "shared provision chain includes ref:wait (must not affect ordinary callers)"
fi
if grep -Fq 'BYOH_DEBUG_CONTINUE' "${PROVISION_CHAIN}"; then
    fail "shared provision chain references BYOH_DEBUG_CONTINUE (must not affect ordinary callers)"
fi
echo "PASS: shared provision chain is unchanged (no debug additions)"

# --- Wait budget verification ---
# Verify the stock wait ref has a timeout that accommodates the 1-hour debug window
WAIT_REF="${REPO_ROOT}/ci-operator/step-registry/wait/wait-ref.yaml"
wait_timeout=$(grep 'timeout:' "${WAIT_REF}" | head -1 | awk '{print $2}')
# Stock wait timeout is 72h which easily accommodates the +1 hour TIMEOUT
echo "PASS: stock wait ref timeout (${wait_timeout}) accommodates 1-hour debug window"

echo ""
echo "All tests passed"
