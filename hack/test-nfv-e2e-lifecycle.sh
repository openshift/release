#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMMANDS="${SCRIPT_DIR%/hack}/ci-operator/step-registry/openshift-qe/rhoso/nfv-e2e/lifecycle/openshift-qe-rhoso-nfv-e2e-lifecycle-commands.sh"
WORK_DIR=$(mktemp -d)
cleanup() {
  if [[ -f "${WORK_DIR}/escaped.pid" ]]; then
    kill "$(cat "${WORK_DIR}/escaped.pid")" 2>/dev/null || :
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

export SHARED_DIR="${WORK_DIR}/shared"
export ARTIFACT_DIR="${SHARED_DIR}"
bash "${COMMANDS}" >/dev/null
# shellcheck source=/dev/null
source "${SHARED_DIR}/openshift-qe-rhoso-nfv-e2e-lifecycle.sh"
generated_nonce=$(_lifecycle_nonce)
[[ "${generated_nonce}" =~ ^[A-Fa-f0-9]{24}$ ]]
export LIFECYCLE_NONCE=caller-controlled
ignored_nonce=$(_lifecycle_nonce)
[[ "${ignored_nonce}" =~ ^[A-Fa-f0-9]{24}$ && "${ignored_nonce}" != caller-controlled ]]
# shellcheck disable=SC2317
_lifecycle_nonce() { printf '%s' deadbeef; }

FAKE_COLLIDE=false
FAKE_RESERVE_LOST=false
FAKE_START_UNACKED=false
FAKE_NEVER_TERMINAL=false
FAKE_CANCEL_NOOP=false
FAKE_LATE_COMPLETION=false
FAKE_CANCEL_REQUESTED=false
FAKE_SUPERVISOR_GONE=false
FAKE_WAIT_FAILURE=0
FAKE_RECORD="${WORK_DIR}/record"
FAKE_RUN_DIR_FILE="${WORK_DIR}/run-dir"
FAKE_RUN_ID_FILE="${WORK_DIR}/run-id"
FAKE_KIND_FILE="${WORK_DIR}/kind"
FAKE_BUILD_ID_FILE="${WORK_DIR}/build-id"
FAKE_STATE_FILE="${WORK_DIR}/state"
FAKE_TERMINAL_CAUSE_FILE="${WORK_DIR}/terminal-cause"
FAKE_SUPERVISOR_PID_FILE="${WORK_DIR}/supervisor-pid"
FAKE_WORKLOAD_STARTED_FILE="${WORK_DIR}/workload-started"
FAKE_POLLS_FILE="${WORK_DIR}/polls"
FAKE_CLEANUP_FILE="${WORK_DIR}/cleanup"
FAKE_EXIT_FILE="${WORK_DIR}/exit"
FAKE_HEARTBEAT_FAILURES=0
FAKE_POLL_FAILURES=0
FAKE_COLLECT_FAILURES=0
FAKE_RESERVE_FAILURES=0
FAKE_START_FAILURES=0
FAKE_SUPERVISOR_LOG_FAILURES=0
FAKE_CANCEL_FAILURES=0
FAKE_SIGNAL=
FAKE_SIGNAL_PID_FILE=
FAKE_SIGNAL_SENT_FILE=
FAKE_SUPERVISOR_TICKS_FILE="${WORK_DIR}/supervisor-ticks"
FAKE_SUPERVISOR_IDENTITY_FILE="${WORK_DIR}/supervisor-identity"
FAKE_COUNTER_DIR="${WORK_DIR}/counters"
fake_state() { [[ -f "${FAKE_STATE_FILE}" ]] && cat "${FAKE_STATE_FILE}" || printf '%s\n' reserved; }
fake_cleanup() { [[ -f "${FAKE_CLEANUP_FILE}" ]] && cat "${FAKE_CLEANUP_FILE}" || printf '%s\n' verified; }
fake_exit() { [[ -f "${FAKE_EXIT_FILE}" ]] && cat "${FAKE_EXIT_FILE}" || printf '%s\n' 0; }
fake_auth_tag() {
  local state="$1" workload_status="$2" workload_exit="$3" cause="$4" cleanup="$5"
  printf '%s' "$(cat "${FAKE_RUN_ID_FILE}")|fake-verifier|1|1|${state}|${workload_status}|${workload_exit}|${cause}|${cleanup}" |
    sha256sum | cut -d' ' -f1
}
fake_fail() {
  local name="$1" configured remaining counter_file current
  counter_file="${FAKE_COUNTER_DIR}/${name}"
  mkdir -p "${FAKE_COUNTER_DIR}"
  current="${!name}"
  if [[ ! -f "${counter_file}" ]]; then
    printf '%s %s\n' "$current" "$current" >"${counter_file}"
  fi
  read -r configured remaining <"${counter_file}"
  if [[ "$configured" != "$current" ]]; then
    configured="$current"
    remaining="$current"
  fi
  if (( remaining > 0 )); then
    remaining=$((remaining - 1))
    printf '%s %s\n' "$configured" "$remaining" >"${counter_file}"
    return 0
  fi
  printf '%s %s\n' "$configured" "$remaining" >"${counter_file}"
  return 1
}
fake_expect_run() {
  [[ "$1" == "$(cat "${FAKE_RUN_DIR_FILE}")" &&
    "$2" == "$(cat "${FAKE_RUN_ID_FILE}")" ]]
}
# shellcheck disable=SC2317
lifecycle_remote_provider() {
  local op="$1"
  shift
  case "${op}" in
    reserve)
      local run_dir="$1" run_id="$2" kind="$3" build_id="$4"
      [[ "${FAKE_COLLIDE}" != true && "${FAKE_RESERVE_LOST}" != true ]] || return 1
      mkdir -p "${FAKE_RECORD}"
      printf '%s\n' "$run_dir" >"${FAKE_RUN_DIR_FILE}"
      printf '%s\n' "$run_id" >"${FAKE_RUN_ID_FILE}"
      printf '%s\n' "$kind" >"${FAKE_KIND_FILE}"
      printf '%s\n' "$build_id" >"${FAKE_BUILD_ID_FILE}"
      printf '%s\n' reserved >"${FAKE_STATE_FILE}"
      printf '%s\n' fake-verifier >"${FAKE_RECORD}/verifier"
      printf '%s\n' completion >"${FAKE_TERMINAL_CAUSE_FILE}"
      printf '%s\n' 0 >"${FAKE_POLLS_FILE}"
      printf '%s\n' verified >"${FAKE_CLEANUP_FILE}"
      printf '%s\n' 0 >"${FAKE_EXIT_FILE}"
      if fake_fail FAKE_RESERVE_FAILURES; then
        FAKE_RESERVE_LOST=true
        return 1
      fi
      printf 'reserved verifier=fake-verifier epoch=1\n'
      ;;
    start)
      local run_dir="$1" run_id="$2" kind="$3" command_payload="$4" capability="$5" cleanup_grace="$6" expected_command command build_id
      build_id=$(<"${FAKE_BUILD_ID_FILE}")
      expected_command='exec make e2e'
      [[ "$kind" == crucible ]] && expected_command='exec make e2e-crucible'
      command=$(printf '%s' "$command_payload" | base64 -d)
      fake_expect_run "$run_dir" "$run_id" &&
        [[ "$kind" == "$(cat "${FAKE_KIND_FILE}")" &&
          "$capability" == fake-verifier &&
          "$cleanup_grace" =~ ^[1-9][0-9]*$ &&
          "$command" == "$expected_command"* ]] || return 1
      if [[ -n "${ADAPTER_ARGS:-}" ]]; then
        printf '%s\n' "$kind" >"${ADAPTER_ARGS}"
        printf 'build_id=%s\ncommand=%s\ncleanup_grace=%s\nwait_timeout=%s\n' \
          "$build_id" "$command" "$cleanup_grace" "${LIFECYCLE_WAIT_TIMEOUT_SECONDS:-unset}" >>"${ADAPTER_ARGS}"
      fi
      if [[ "${FAKE_START_UNACKED}" == true ]]; then
        printf '%s\n' running >"${FAKE_STATE_FILE}"
        printf '%s\n' 4242 >"${FAKE_SUPERVISOR_PID_FILE}"
        printf '%s\n' 1 >"${FAKE_SUPERVISOR_TICKS_FILE}"
        printf '%s\n' "4242:${run_id}" >"${FAKE_SUPERVISOR_IDENTITY_FILE}"
        printf '%s\n' 1 >"${FAKE_WORKLOAD_STARTED_FILE}"
        printf '%s\n' 143 >"${FAKE_EXIT_FILE}"
        printf '%s\n' startup_recovery >"${FAKE_TERMINAL_CAUSE_FILE}"
        return 1
      fi
      printf '%s\n' running >"${FAKE_STATE_FILE}"
      printf '%s\n' 4242 >"${FAKE_SUPERVISOR_PID_FILE}"
      printf '%s\n' 1 >"${FAKE_SUPERVISOR_TICKS_FILE}"
      printf '%s\n' "4242:${run_id}" >"${FAKE_SUPERVISOR_IDENTITY_FILE}"
      if fake_fail FAKE_START_FAILURES; then
        return 1
      fi
      printf '%s\n' 0 >"${FAKE_POLLS_FILE}"
      printf '%s\n' started
      ;;
    heartbeat)
      fake_expect_run "$1" "$2" || return 1
      fake_fail FAKE_HEARTBEAT_FAILURES && return 1
      [[ "$(fake_state)" != terminal && "$(fake_state)" != cleanup_failed ]]
      printf '%s\n' heartbeat
      ;;
    poll)
      fake_expect_run "$1" "$2" || return 1
      if [[ -n "${FAKE_SIGNAL:-}" && -n "${FAKE_SIGNAL_PID_FILE:-}" &&
        ! -e "${FAKE_SIGNAL_SENT_FILE:-}" ]]; then
        : >"${FAKE_SIGNAL_SENT_FILE}"
        signal_pid=$(<"${FAKE_SIGNAL_PID_FILE}")
        kill "-${FAKE_SIGNAL}" "$signal_pid" 2>/dev/null || :
        if [[ "${FAKE_SIGNAL}" == INT ]]; then
          ( sleep 1; kill -TERM "$signal_pid" 2>/dev/null || : ) &
        fi
      fi
      fake_fail FAKE_POLL_FAILURES && return 1
      [[ "${FAKE_WAIT_FAILURE}" != 1 ]] || return 17
      while [[ "${FAKE_WAIT_BLOCK:-false}" == true &&
        ( -z "${FAKE_CANCEL_FILE:-}" || ! -e "${FAKE_CANCEL_FILE}" ) ]]; do
        sleep 1
      done
      local polls supervisor_pid supervisor_liveness launcher_liveness
      polls=$(( $(<"${FAKE_POLLS_FILE}") + 1 ))
      printf '%s\n' "${polls}" >"${FAKE_POLLS_FILE}"
      if [[ "${FAKE_SUPERVISOR_GONE}" == true && "$polls" -ge 2 ]]; then
        printf '%s\n' cleanup_failed >"${FAKE_STATE_FILE}"
        printf '%s\n' dead_supervisor >"${FAKE_TERMINAL_CAUSE_FILE}"
      elif [[ "${FAKE_LATE_COMPLETION}" == true &&
        ( "${FAKE_CANCEL_REQUESTED}" == true ||
          ( -n "${FAKE_CANCEL_FILE:-}" && -e "${FAKE_CANCEL_FILE}" ) ) ]]; then
        printf '%s\n' terminal >"${FAKE_STATE_FILE}"
      elif [[ "${FAKE_NEVER_TERMINAL}" != true && "$polls" -ge 2 ]]; then
        printf '%s\n' terminal >"${FAKE_STATE_FILE}"
      fi
      supervisor_pid=4242
      [[ "${FAKE_START_UNACKED}" == true || "${FAKE_SUPERVISOR_GONE}" == true ]] && supervisor_pid=
      supervisor_liveness=not-live
      [[ -n "$supervisor_pid" ]] && supervisor_liveness=validated-live
      launcher_liveness=unknown
      printf 'run_id=%s\nkind=%s\nbuild_id=%s\nstate=%s\nworkload_exit=%s\ncleanup_status=%s\nworkload_status=exited\nterminal_cause=%s\nsupervisor_pid=%s\nsupervisor_identity=%s\nsupervisor_start_ticks=%s\nsupervisor_liveness=%s\nlauncher_pid=%s\nlauncher_identity=%s\nlauncher_start_ticks=%s\nlauncher_liveness=%s\n' \
        "$(cat "${FAKE_RUN_ID_FILE}")" "$(cat "${FAKE_KIND_FILE}")" "$(cat "${FAKE_BUILD_ID_FILE}")" \
        "$(fake_state)" "$(fake_exit)" "$(fake_cleanup)" "$(cat "${FAKE_TERMINAL_CAUSE_FILE}")" "$supervisor_pid" \
        "$(cat "${FAKE_SUPERVISOR_IDENTITY_FILE}" 2>/dev/null || :)" "$(cat "${FAKE_SUPERVISOR_TICKS_FILE}" 2>/dev/null || :)" \
        "$supervisor_liveness" "" "" "" "$launcher_liveness"
      printf 'owner_epoch=1\nrecord_sequence=1\ncontroller_user=fake-controller\nworkload_user=fake-workload\nterminal_published=%s\nrecord_auth=%s\n' \
        "$([[ "$(fake_state)" == terminal || "$(fake_state)" == cleanup_failed ]] && printf true || printf false)" \
        "$(fake_auth_tag "$(fake_state)" exited "$(fake_exit)" "$(cat "${FAKE_TERMINAL_CAUSE_FILE}")" "$(fake_cleanup)")"
      ;;
    cancel)
      fake_expect_run "$1" "$2" || return 1
      fake_fail FAKE_CANCEL_FAILURES && return 1
      [[ -z "${FAKE_CANCEL_FILE:-}" ]] || : >"${FAKE_CANCEL_FILE}"
      if [[ "${FAKE_CANCEL_NOOP}" == true ]]; then
        FAKE_CANCEL_REQUESTED=true
        printf '%s\n' cancel_requested
      else
        printf '%s\n' terminal >"${FAKE_STATE_FILE}"
        printf '%s\n' 143 >"${FAKE_EXIT_FILE}"
        printf '%s\n' verified >"${FAKE_CLEANUP_FILE}"
        printf '%s\n' cancel_requested >"${FAKE_TERMINAL_CAUSE_FILE}"
        printf '%s\n' cancel_requested
      fi
      ;;
    collect)
      fake_expect_run "$1" "$2" || return 1
      fake_fail FAKE_COLLECT_FAILURES && return 1
      printf 'run_id=%s\nkind=%s\nbuild_id=%s\nstate=%s\nworkload_status=exited\nworkload_exit=%s\nterminal_cause=%s\ncleanup_status=%s\ncleanup_evidence=PID_123\nowner_epoch=1\nrecord_sequence=1\ncontroller_user=fake-controller\nworkload_user=fake-workload\nterminal_published=true\nrecord_auth=%s\n' \
        "$(cat "${FAKE_RUN_ID_FILE}")" "$(cat "${FAKE_KIND_FILE}")" "$(cat "${FAKE_BUILD_ID_FILE}")" \
        "$(fake_state)" "$(fake_exit)" "$(cat "${FAKE_TERMINAL_CAUSE_FILE}")" "$(fake_cleanup)" \
        "$(fake_auth_tag "$(fake_state)" exited "$(fake_exit)" "$(cat "${FAKE_TERMINAL_CAUSE_FILE}")" "$(fake_cleanup)")"
      ;;
    collect_log)
      fake_expect_run "$1" "$2" || return 1
      case "$3" in
        workload)
          cat <<'EOF'
workload complete
TOKEN=workload-secret
AWS_SECRET_ACCESS_KEY=top-secret
AWS_ACCESS_KEY_ID=access-key-id-secret
--password cli-secret
password="foo bar baz"
password: colon-secret
token: colon-token
'token': 'json-secret'
Authorization: Bearer bearer-secret
password: |
  block-secret
TOKEN: |
  uppercase-block-secret
password:
  continuation-secret
--password=equals-secret
curl -u user:curl-secret https://user:url-secret@example.test
-----BEGIN PRIVATE KEY-----
private-key-secret
-----END PRIVATE KEY-----
EOF
          ;;
        supervisor) fake_fail FAKE_SUPERVISOR_LOG_FAILURES && return 1; printf 'supervisor complete\npassword=supervisor-secret\ntoken whitespace-secret\n{"token":"json-token-secret"}\n' ;;
        *) return 64 ;;
      esac
      ;;
    *)
      return 64
      ;;
  esac
}

export -f lifecycle_remote_provider fake_fail fake_expect_run fake_state fake_cleanup fake_exit
export FAKE_COUNTER_DIR

expect_failure() {
  local label="$1"
  shift
  if "$@"; then
    printf 'expected failure: %s\n' "${label}" >&2
    exit 1
  fi
}
set_fake_run() {
  local state="${1:-running}" cleanup="${2:-verified}" exit_code="${3:-0}" polls="${4:-0}"
  printf '%s\n' "$state" >"${FAKE_STATE_FILE}"
  printf '%s\n' "$cleanup" >"${FAKE_CLEANUP_FILE}"
  printf '%s\n' "$exit_code" >"${FAKE_EXIT_FILE}"
  printf '%s\n' "$polls" >"${FAKE_POLLS_FILE}"
  printf '%s\n' "$([[ "$exit_code" == 0 ]] && printf completion || printf failure)" >"${FAKE_TERMINAL_CAUSE_FILE}"
  printf '%s\n' 4242 >"${FAKE_SUPERVISOR_PID_FILE}"
  printf '%s\n' 1 >"${FAKE_SUPERVISOR_TICKS_FILE}"
  printf '%s\n' "4242:$(cat "${FAKE_RUN_ID_FILE}")" >"${FAKE_SUPERVISOR_IDENTITY_FILE}"
  FAKE_CANCEL_REQUESTED=false
}

LIFECYCLE_LEASE_SECONDS=30
LIFECYCLE_CLEANUP_GRACE_SECONDS=2
LIFECYCLE_OPERATION_TIMEOUT_SECONDS=5

expect_failure 'invalid build identity' lifecycle_start 'bad identity' deployment "${WORK_DIR}/remote" make e2e
saved_lease="${LIFECYCLE_LEASE_SECONDS}"
saved_operation_timeout="${LIFECYCLE_OPERATION_TIMEOUT_SECONDS}"
LIFECYCLE_LEASE_SECONDS=10
LIFECYCLE_OPERATION_TIMEOUT_SECONDS=5
expect_failure 'retry budget exceeds lease' lifecycle_start build-123 deployment "${WORK_DIR}/remote" make e2e
LIFECYCLE_LEASE_SECONDS="${saved_lease}"
LIFECYCLE_OPERATION_TIMEOUT_SECONDS="${saved_operation_timeout}"
expect_failure 'invalid workload kind' lifecycle_start build-123 unsupported "${WORK_DIR}/remote" make e2e
expect_failure 'invalid workspace' lifecycle_start build-123 deployment relative make e2e

lifecycle_start build-123 deployment "${WORK_DIR}/remote" make e2e >"${WORK_DIR}/run-id"
run_id=$(<"${WORK_DIR}/run-id")
[[ "${run_id}" == deployment-build-123-deadbeef ]]
[[ "${LIFECYCLE_RUN_ID}" == "${run_id}" ]]
[[ "$(fake_state)" == running ]]

lifecycle_wait
[[ "$(<"${FAKE_POLLS_FILE}")" -ge 2 ]]
[[ "$(fake_state)" == terminal ]]
[[ -s "${SHARED_DIR}/nfv-e2e-lifecycle-${run_id}.txt" ]]
[[ -s "${SHARED_DIR}/nfv-e2e-lifecycle-${run_id}-workload.log" ]]
[[ -s "${SHARED_DIR}/nfv-e2e-lifecycle-${run_id}-supervisor.log" ]]
workload_log=$(<"${SHARED_DIR}/nfv-e2e-lifecycle-${run_id}-workload.log")
supervisor_log=$(<"${SHARED_DIR}/nfv-e2e-lifecycle-${run_id}-supervisor.log")
[[ "${workload_log}" == *'workload complete'* && "${workload_log}" == *'<REDACTED>'* && "${workload_log}" != *'workload-secret'* && "${workload_log}" != *'top-secret'* && "${workload_log}" != *'access-key-id-secret'* && "${workload_log}" != *'foo bar baz'* && "${workload_log}" != *'json-secret'* && "${workload_log}" != *'cli-secret'* && "${workload_log}" != *'colon-secret'* && "${workload_log}" != *'colon-token'* && "${workload_log}" != *'bearer-secret'* && "${workload_log}" != *'basic-secret'* && "${workload_log}" != *'curl-secret'* && "${workload_log}" != *'url-secret'* && "${workload_log}" != *'pem-secret'* && "${workload_log}" != *'private-key-secret'* && "${workload_log}" != *'block-secret' ]]
[[ "${supervisor_log}" == *'supervisor complete'* && "${supervisor_log}" == *'<REDACTED>'* && "${supervisor_log}" != *'supervisor-secret'* && "${supervisor_log}" != *'whitespace-secret'* && "${supervisor_log}" != *'json-token-secret' ]]
[[ "${workload_log}" != *'uppercase-block-secret'* && "${workload_log}" != *'continuation-secret'* && "${workload_log}" != *'equals-secret'* ]]
evidence=$(<"${SHARED_DIR}/nfv-e2e-lifecycle-${run_id}.txt")
[[ "${evidence}" != *SECRET* && "${evidence}" != *TOKEN* && "${evidence}" != *KUBECONFIG* ]]

set_fake_run running failed 1 0
if lifecycle_wait; then
  printf 'cleanup failure must fail lifecycle_wait\n' >&2
  exit 1
fi
set_fake_run terminal failed 0 0
expect_failure 'cleanup failure with successful workload' lifecycle_wait
set_fake_run terminal verified 1 0
expect_failure 'workload failure with verified cleanup' lifecycle_wait
FAKE_SUPERVISOR_GONE=true
set_fake_run running verified 0 1
expect_failure 'dead supervisor recovery' lifecycle_wait
[[ "${LIFECYCLE_LAST_STATE}" == *'terminal_cause=dead_supervisor'* ]]
FAKE_SUPERVISOR_GONE=false


set_fake_run running verified 0 0
LIFECYCLE_RECONNECT_ATTEMPTS=3
FAKE_CANCEL_FAILURES="${LIFECYCLE_RECONNECT_ATTEMPTS}"
expect_failure 'exhausted cancellation failure' lifecycle_cancel cancelled
[[ "${LIFECYCLE_CANCEL_FAILED}" == true ]]
FAKE_CANCEL_FAILURES=0
set_fake_run terminal failed 143 0
expect_failure 'cancel failure terminal outcome' lifecycle_wait

expect_failure 'invalid cancellation reason' lifecycle_cancel 'bad reason'
FAKE_HEARTBEAT_FAILURES=1
FAKE_POLL_FAILURES=2
FAKE_COLLECT_FAILURES=1
LIFECYCLE_RECONNECT_ATTEMPTS=3
set_fake_run running verified 0 0
lifecycle_wait

FAKE_POLL_FAILURES=100
LIFECYCLE_RECONNECT_ATTEMPTS=2
set_fake_run running verified 0 0
poll_transport_failure="${SHARED_DIR}/nfv-e2e-lifecycle-${run_id}-transport-failure-poll_recovery.txt"
expect_failure 'poll reconnect exhaustion' lifecycle_wait
[[ -s "${poll_transport_failure}" && "$(cat "${poll_transport_failure}")" == *'operation=poll_recovery'* ]]
FAKE_POLL_FAILURES=0
FAKE_COLLECT_FAILURES=100
set_fake_run terminal verified 0 0
collect_transport_failure="${SHARED_DIR}/nfv-e2e-lifecycle-${run_id}-transport-failure-collect.txt"
expect_failure 'collect reconnect exhaustion' lifecycle_wait
[[ -s "${collect_transport_failure}" && "$(cat "${collect_transport_failure}")" == *'operation=collect'* ]]
FAKE_COLLECT_FAILURES=0
FAKE_HEARTBEAT_FAILURES=0
lifecycle_start build-partial deployment "${WORK_DIR}/remote" make e2e >/dev/null
run_id="${LIFECYCLE_RUN_ID}"
set_fake_run terminal verified 0 0
FAKE_SUPERVISOR_LOG_FAILURES=100
expect_failure 'partial terminal collection' lifecycle_collect
[[ -s "${SHARED_DIR}/nfv-e2e-lifecycle-${run_id}.txt" ]]
[[ -s "${SHARED_DIR}/nfv-e2e-lifecycle-${run_id}-workload.log" ]]
[[ ! -e "${SHARED_DIR}/nfv-e2e-lifecycle-${run_id}-supervisor.log" ]]
FAKE_SUPERVISOR_LOG_FAILURES=0

LIFECYCLE_WAIT_TIMEOUT_SECONDS=1
FAKE_NEVER_TERMINAL=true
LIFECYCLE_RECONNECT_ATTEMPTS=1
set_fake_run running verified 0 0
expect_failure 'wait timeout cancellation' lifecycle_wait
[[ "$(fake_state)" == terminal && "$(fake_exit)" == 143 ]]
FAKE_CANCEL_NOOP=true
FAKE_LATE_COMPLETION=true
FAKE_NEVER_TERMINAL=true
FAKE_CANCEL_FILE="${WORK_DIR}/late-cancel"
export FAKE_CANCEL_FILE
LIFECYCLE_WAIT_TIMEOUT_SECONDS=1
LIFECYCLE_RECONNECT_ATTEMPTS=1
set_fake_run running verified 0 0
expect_failure 'late completion after timeout cancellation' lifecycle_wait
[[ "$(fake_state)" == terminal ]]
FAKE_CANCEL_NOOP=false
FAKE_LATE_COMPLETION=false
FAKE_NEVER_TERMINAL=false
LIFECYCLE_WAIT_TIMEOUT_SECONDS=43200
LIFECYCLE_RECONNECT_ATTEMPTS=3

timeout_transport_failure="${SHARED_DIR}/nfv-e2e-lifecycle-${run_id}-transport-failure-wait_timeout.txt"
[[ -s "${timeout_transport_failure}" && "$(cat "${timeout_transport_failure}")" == *'operation=wait_timeout'* ]]
FAKE_NEVER_TERMINAL=false
LIFECYCLE_WAIT_TIMEOUT_SECONDS=43200
LIFECYCLE_RECONNECT_ATTEMPTS=3

FAKE_RESERVE_FAILURES=1
FAKE_RESERVE_LOST=false
lifecycle_start build-reserve-ack deployment "${WORK_DIR}/remote" make e2e >/dev/null
[[ "${LIFECYCLE_RUN_ID}" == deployment-build-reserve-ack-deadbeef ]]
FAKE_RESERVE_FAILURES=0
FAKE_RESERVE_LOST=false

FAKE_START_FAILURES=3

FAKE_START_UNACKED=true
FAKE_NEVER_TERMINAL=true
LIFECYCLE_RECONNECT_ATTEMPTS=1
expect_failure 'startup acknowledgement recovery' lifecycle_start build-start-lost deployment "${WORK_DIR}/remote" make e2e
startup_run_id="${LIFECYCLE_RUN_ID}"
[[ -s "${SHARED_DIR}/nfv-e2e-lifecycle-${startup_run_id}.txt" ]]
[[ -s "${SHARED_DIR}/nfv-e2e-lifecycle-${startup_run_id}-workload.log" ]]
startup_failure="${SHARED_DIR}/nfv-e2e-lifecycle-${startup_run_id}-startup-failure.txt"
[[ -s "${startup_failure}" && "$(cat "${startup_failure}")" == *'state=startup_recovery_failed'* ]]
FAKE_NEVER_TERMINAL=false
FAKE_START_UNACKED=false
lifecycle_start build-start-ack deployment "${WORK_DIR}/remote" make e2e >/dev/null
[[ "${LIFECYCLE_RUN_ID}" == deployment-build-start-ack-deadbeef ]]
FAKE_START_FAILURES=0

FAKE_SSH_ARGS="${WORK_DIR}/ssh-args"
FAKE_INNER_ARGS="${WORK_DIR}/inner-args"
FAKE_SSH_SCRIPT="${WORK_DIR}/ssh-script"
FAKE_INNER_PAYLOAD="${WORK_DIR}/inner-payload"
FAKE_KNOWN_HOSTS_PAYLOAD="${WORK_DIR}/known-hosts-payload"
FAKE_TIMEOUT_ARGS="${WORK_DIR}/timeout-args"
: >"${FAKE_TIMEOUT_ARGS}"
cat >"${WORK_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
separator=-1
for i in "${!args[@]}"; do
  [[ "${args[$i]}" == -- ]] && separator="$i" && break
done
if [[ " ${args[*]} " == *" root@jumphost.example "* &&
  " ${args[*]} " == *"base64 -d >"* ]]; then
  cat >"${FAKE_KNOWN_HOSTS_PAYLOAD}"
  printf '%s\n' '/tmp/nfv-e2e-known-hosts.fake'
  exit 0
fi
(( separator >= 0 ))
if [[ " ${args[*]} " == *" root@jumphost.example "* ]]; then
  printf '%s\n' "${args[@]}" >"${FAKE_SSH_ARGS}"
  cat >"${FAKE_SSH_SCRIPT}"
  bash "${FAKE_SSH_SCRIPT}" "${args[@]:$((separator + 1))}"
else
  printf '%s\n' "${args[@]}" >"${FAKE_INNER_ARGS}"
  remote_args=("${args[@]:$((separator + 1))}")
  run_dir="${remote_args[2]}"
  run_id="${remote_args[3]}"
  mkdir -p "${run_dir}"
  payload=$(cat)
  if (( ${#remote_args[@]} < 5 )); then
    remote_args+=(compat-verifier 1)
  fi
  printf '%s\n' "${run_id}" >"${run_dir}/run_id"
  printf '%s\n' "$(id -un)" >"${run_dir}/owner"
  printf '%s\n' "$(id -un)" >"${run_dir}/controller_user"
  printf '%s\n' "${remote_args[4]}" >"${run_dir}/auth_capability"
  printf '%s\n' 1 >"${run_dir}/owner_epoch"
  printf '%s\n' 0 >"${run_dir}/record.sequence"
  printf '%s' "${payload}" >"${FAKE_INNER_PAYLOAD}"
  printf '%s' "${payload}" | bash -s -- "${remote_args[@]}"
  exit "${FAKE_INNER_EXIT:-0}"
fi
EOF
cat >"${WORK_DIR}/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
duration="${1:?timeout duration required}"
[[ "$duration" =~ ^[1-9][0-9]*$ ]] || {
  printf 'invalid timeout duration: %s\n' "$duration" >&2
  exit 64
}
printf '%s\n' "$duration" >>"${FAKE_TIMEOUT_ARGS}"
shift
exec /usr/bin/timeout "$duration" "$@"
EOF
chmod 700 "${WORK_DIR}/ssh" "${WORK_DIR}/timeout"
export FAKE_SSH_ARGS FAKE_INNER_ARGS FAKE_SSH_SCRIPT FAKE_INNER_PAYLOAD FAKE_KNOWN_HOSTS_PAYLOAD FAKE_INNER_EXIT FAKE_TIMEOUT_ARGS
export LIFECYCLE_JUMPHOST=jumphost.example LIFECYCLE_BASTION=bastion.example LIFECYCLE_CONTROLLER_USER="$(id -un)"
PATH="${WORK_DIR}:${PATH}"
_lifecycle_ssh_remote poll /tmp/nfv-e2e-lifecycle/run-id deployment >/dev/null
timeout_calls=$(wc -l <"${FAKE_TIMEOUT_ARGS}")
(( timeout_calls >= 2 ))
while IFS= read -r timeout_duration; do
  [[ "$timeout_duration" =~ ^[1-9][0-9]*$ ]]
done <"${FAKE_TIMEOUT_ARGS}"
ssh_args=$(<"${FAKE_SSH_ARGS}")
inner_args=$(<"${FAKE_INNER_ARGS}")
ssh_script=$(<"${FAKE_SSH_SCRIPT}")
inner_payload=$(<"${FAKE_INNER_PAYLOAD}")
[[ "${ssh_args}" == *'StrictHostKeyChecking=no'* ]]
[[ "${ssh_args}" == *'UserKnownHostsFile=/dev/null'* ]]
[[ "${ssh_args}" == *'ServerAliveInterval=60'* ]]
[[ "${ssh_args}" == *'ServerAliveCountMax=240'* ]]
[[ "${ssh_args}" == *'ConnectTimeout=30'* ]]
[[ "${inner_args}" == *'bastion.example'* && "${inner_args}" == *'poll'* ]]
[[ "${inner_payload}" == *'_lifecycle_remote_agent "$@"'* ]]
[[ "${ssh_script}" == *'StrictHostKeyChecking=${host_key_mode}'* ]]
[[ "${ssh_script}" == *'ssh "${ssh_args[@]}" zuul@"$bastion" bash -s -- "$bastion" "$op" "$@"'* ]]
[[ "${ssh_script}" == *'UserKnownHostsFile=${host_key_file}'* ]]
[[ "${ssh_script}" == *'ServerAliveInterval=${alive_interval}'* ]]
[[ "${ssh_script}" == *'ServerAliveCountMax=${alive_count}'* ]]
FAKE_INNER_EXIT=23
expect_failure 'two-hop status propagation' _lifecycle_ssh_remote poll /tmp/nfv-e2e-lifecycle/run-id deployment
FAKE_INNER_EXIT=0
known_hosts="${WORK_DIR}/known_hosts"
printf '%s\n' 'jumphost.example ssh-ed25519 AAAA' >"${known_hosts}"
CLUSTER_PROFILE_DIR="${WORK_DIR}"
LIFECYCLE_KNOWN_HOSTS="${known_hosts}"
_lifecycle_ssh_remote poll /tmp/nfv-e2e-lifecycle/run-id deployment >/dev/null
ssh_args=$(<"${FAKE_SSH_ARGS}")
ssh_script=$(<"${FAKE_SSH_SCRIPT}")
[[ "${ssh_args}" == *'StrictHostKeyChecking=yes'* ]]
[[ "${ssh_args}" == *"UserKnownHostsFile=${known_hosts}"* ]]
[[ "$(base64 -d <"${FAKE_KNOWN_HOSTS_PAYLOAD}")" == "$(cat "${known_hosts}")" ]]
known_hosts_link="${WORK_DIR}/known_hosts-link"
ln -s "${known_hosts}" "${known_hosts_link}"
LIFECYCLE_KNOWN_HOSTS="${known_hosts_link}"
expect_failure 'symlinked known-hosts file' _lifecycle_ssh_remote poll /tmp/nfv-e2e-lifecycle/run-id deployment
LIFECYCLE_KNOWN_HOSTS="${known_hosts}"
[[ "${ssh_script}" == *'remote_known_hosts'* ]]
[[ "${ssh_script}" != *'known_hosts_payload'* ]]
unset LIFECYCLE_KNOWN_HOSTS CLUSTER_PROFILE_DIR LIFECYCLE_JUMPHOST LIFECYCLE_BASTION FAKE_SSH_ARGS FAKE_SSH_SCRIPT
PATH="${PATH#${WORK_DIR}:}"

FAKE_COLLECT_FAILURES=0
FAKE_PROVIDER_DEFINITION="$(declare -f fake_auth_tag; declare -f lifecycle_remote_provider)"
unset -f lifecycle_remote_provider
export LIFECYCLE_LOCAL_REMOTE=true
export SHARED_DIR="${WORK_DIR}/local-shared" ARTIFACT_DIR="${WORK_DIR}/local-shared"
mkdir -p "${SHARED_DIR}"
bash "${COMMANDS}" >/dev/null
# shellcheck source=/dev/null
source "${SHARED_DIR}/openshift-qe-rhoso-nfv-e2e-lifecycle.sh"
_lifecycle_nonce() { printf '%s' feed1234; }
LIFECYCLE_RECONNECT_ATTEMPTS=2
LIFECYCLE_POLL_SECONDS=1
LIFECYCLE_CLEANUP_GRACE_SECONDS=1
LIFECYCLE_LEASE_SECONDS=15
escaped_workload="${WORK_DIR}/escaped-workload.sh"
cat >"${escaped_workload}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$PWD" >"$NFV_E2E_WORKSPACE/workload.cwd"
setsid sh -c 'sleep 30 & echo $! >"$NFV_E2E_WORKSPACE/escaped.pid"; exit 0' >/dev/null 2>&1 &
sleep 1
exit 0
EOF
chmod 700 "${escaped_workload}"
lifecycle_start build-escaped deployment "${WORK_DIR}/local-remote" "$escaped_workload"
lifecycle_wait
escaped_run_dir="${LIFECYCLE_RUN_DIR}"
escaped_record=$(awk '/^PID=[0-9]+/ && /COMM=sleep([[:space:]]|$)/ { print; exit }' \
  "${escaped_run_dir}/cleanup_evidence")
[[ "$escaped_record" =~ ^PID=([0-9]+)[[:space:]]+ ]]
escaped_pid="${BASH_REMATCH[1]}"
[[ "$escaped_pid" =~ ^[0-9]+$ ]]
[[ "$escaped_record" == *'COMM=sleep'* ]]
! kill -0 "${escaped_pid}" 2>/dev/null
[[ "${LIFECYCLE_LAST_STATE}" == *'state=terminal'* ]]
[[ "${LIFECYCLE_LAST_STATE}" == *'workload_exit=0'* ]]
[[ "${LIFECYCLE_LAST_STATE}" == *'cleanup_status=verified'* ]]
[[ "$(<"${WORK_DIR}/local-remote/workload.cwd")" == "${WORK_DIR}/local-remote" ]]
recovery_workload="${WORK_DIR}/recovery-workload.sh"
cat >"${recovery_workload}" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod 700 "${recovery_workload}"
lifecycle_start build-recovery deployment "${WORK_DIR}/local-recovery" "$recovery_workload" >/dev/null
recovery_dir="${LIFECYCLE_RUN_DIR}"
for _ in {1..50}; do
  [[ -s "${recovery_dir}/supervisor_pid" ]] && break
  sleep 0.1
done
recovery_supervisor_pid=$(<"${recovery_dir}/supervisor_pid")
[[ "$recovery_supervisor_pid" =~ ^[0-9]+$ ]]
kill -KILL "$recovery_supervisor_pid"
expect_failure 'real dead supervisor recovery' lifecycle_wait
[[ "$(<"${recovery_dir}/state")" == cleanup_failed ]]

saved_run_id="${LIFECYCLE_RUN_ID}"
LIFECYCLE_RUN_ID=deployment-foreign-feed1234
expect_failure 'foreign run directory' lifecycle_poll "${WORK_DIR}/local-remote/.nfv-e2e-lifecycle/${saved_run_id}"
peer_workload="${WORK_DIR}/peer-workload.sh"
cat >"${peer_workload}" <<'EOF'
#!/usr/bin/env bash
trap '' TERM INT
sleep 30
EOF
chmod 700 "${peer_workload}"
lifecycle_start build-peer-a deployment "${WORK_DIR}/local-peer-a" "${peer_workload}" >/dev/null
peer_a_id="${LIFECYCLE_RUN_ID}"
peer_a_verifier="${LIFECYCLE_RECORD_VERIFIER}"
peer_a_epoch="${LIFECYCLE_OWNER_EPOCH}"
peer_a_dir="${LIFECYCLE_RUN_DIR}"
lifecycle_start build-peer-b deployment "${WORK_DIR}/local-peer-b" "${peer_workload}" >/dev/null
peer_b_id="${LIFECYCLE_RUN_ID}"
peer_b_verifier="${LIFECYCLE_RECORD_VERIFIER}"
peer_b_epoch="${LIFECYCLE_OWNER_EPOCH}"
peer_b_dir="${LIFECYCLE_RUN_DIR}"
for peer_dir in "$peer_a_dir" "$peer_b_dir"; do
  for _ in {1..50}; do
    [[ -s "${peer_dir}/workload_pid" ]] && break
    sleep 0.1
  done
done
LIFECYCLE_RECORD_VERIFIER="${peer_b_verifier}"
LIFECYCLE_OWNER_EPOCH="${peer_b_epoch}"
lifecycle_cancel peer_cancel
expect_failure 'peer run cancellation' lifecycle_wait "$peer_b_dir"
[[ "$(<"${peer_a_dir}/state")" == running ]]
peer_a_pid=$(<"${peer_a_dir}/workload_pid")
[[ "$peer_a_pid" =~ ^[0-9]+$ ]]
kill -0 "$peer_a_pid" 2>/dev/null
LIFECYCLE_RUN_ID="$peer_a_id"
LIFECYCLE_RUN_DIR="$peer_a_dir"
LIFECYCLE_RECORD_VERIFIER="${peer_a_verifier}"
LIFECYCLE_OWNER_EPOCH="${peer_a_epoch}"
lifecycle_cancel peer_cancel
expect_failure 'primary run cancellation' lifecycle_wait "$peer_a_dir"
LIFECYCLE_RUN_ID="$peer_b_id"
LIFECYCLE_RUN_DIR="$peer_b_dir"

lifecycle_start build-zombie deployment "${WORK_DIR}/local-zombie" bash -c 'exit 0' >/dev/null
expect_failure 'tracking failure after fast workload exit' lifecycle_wait
[[ "${LIFECYCLE_LAST_STATE}" == *'workload_exit=0'* ]]

lifecycle_start build-mismatch deployment "${WORK_DIR}/local-mismatch" bash -c 'trap "" TERM; sleep 30' >/dev/null
(sleep 30) &
unrelated_pid=$!
printf '%s\n' "${unrelated_pid}" >>"${LIFECYCLE_RUN_DIR}/tracked_pids"
lifecycle_cancel identity_mismatch
lifecycle_wait &
wait_pid=$!
for _ in {1..15}; do
  kill -0 "${wait_pid}" 2>/dev/null || break
  sleep 1
done
if kill -0 "${wait_pid}" 2>/dev/null; then
  kill "${wait_pid}" 2>/dev/null || :
  wait "${wait_pid}" 2>/dev/null || :
  printf 'ambiguous cleanup must finalize within its bounded grace\n' >&2
  exit 1
fi
if wait "${wait_pid}"; then
  printf 'identity mismatch must fail closed\n' >&2
  exit 1
fi
kill -0 "${unrelated_pid}" 2>/dev/null
kill "${unrelated_pid}" 2>/dev/null || :
wait "${unrelated_pid}" 2>/dev/null || :
unset LIFECYCLE_LOCAL_REMOTE

mkdir -p "${WORK_DIR}/deployment-shared" "${WORK_DIR}/crucible-shared"
SHARED_DIR="${WORK_DIR}/deployment-shared" bash "${COMMANDS}" >/dev/null
SHARED_DIR="${WORK_DIR}/crucible-shared" bash "${COMMANDS}" >/dev/null
export FAKE_CANCEL_FAILURES FAKE_START_FAILURES FAKE_SUPERVISOR_LOG_FAILURES
export FAKE_COLLIDE FAKE_RESERVE_LOST FAKE_START_UNACKED FAKE_NEVER_TERMINAL
export FAKE_CANCEL_NOOP FAKE_LATE_COMPLETION FAKE_CANCEL_REQUESTED FAKE_SUPERVISOR_GONE
export FAKE_WAIT_FAILURE FAKE_RECORD FAKE_RUN_DIR_FILE FAKE_RUN_ID_FILE FAKE_KIND_FILE
export FAKE_BUILD_ID_FILE FAKE_STATE_FILE FAKE_TERMINAL_CAUSE_FILE FAKE_SUPERVISOR_PID_FILE
export FAKE_SUPERVISOR_TICKS_FILE FAKE_SUPERVISOR_IDENTITY_FILE FAKE_COUNTER_DIR
export FAKE_WORKLOAD_STARTED_FILE FAKE_POLLS_FILE FAKE_CLEANUP_FILE FAKE_EXIT_FILE
export FAKE_HEARTBEAT_FAILURES FAKE_POLL_FAILURES FAKE_COLLECT_FAILURES FAKE_RESERVE_FAILURES
export FAKE_START_FAILURES FAKE_SUPERVISOR_LOG_FAILURES
REPO_ROOT=$(git rev-parse --show-toplevel)
CONFIG_FILE="${REPO_ROOT}/ci-operator/config/openshift-eng/ocp-qe-perfscale-ci/openshift-eng-ocp-qe-perfscale-ci-main__metal-nfv-e2e-x86.yaml"
PRESUBMIT_FILE="${REPO_ROOT}/ci-operator/jobs/openshift-eng/ocp-qe-perfscale-ci/openshift-eng-ocp-qe-perfscale-ci-main-presubmits.yaml"
grep -Fq -- 'as: nfv-e2e-sriov-tgen-trex-txrx-ptp-lat-intel-11' "${CONFIG_FILE}"
grep -Fq -- 'as: nfv-e2e-ovs-dpdk-tgen-trex-txrx-ptp-lat-intel-11' "${CONFIG_FILE}"
grep -Fq -- 'context: ci/prow/metal-nfv-e2e-x86-nfv-e2e-sriov-tgen-trex-txrx-ptp-lat-intel-11' "${PRESUBMIT_FILE}"
grep -Fq -- 'name: pull-ci-openshift-eng-ocp-qe-perfscale-ci-main-metal-nfv-e2e-x86-nfv-e2e-sriov-tgen-trex-txrx-ptp-lat-intel-11' "${PRESUBMIT_FILE}"
grep -Fq -- 'rerun_command: /test metal-nfv-e2e-x86-nfv-e2e-sriov-tgen-trex-txrx-ptp-lat-intel-11' "${PRESUBMIT_FILE}"
grep -Fq -- '--target=nfv-e2e-sriov-tgen-trex-txrx-ptp-lat-intel-11' "${PRESUBMIT_FILE}"
grep -Fq -- 'metal-nfv-e2e-x86-nfv-e2e-sriov-tgen-trex-txrx-ptp-lat-intel-11|remaining-required' "${PRESUBMIT_FILE}"
grep -Fq -- 'context: ci/prow/metal-nfv-e2e-x86-nfv-e2e-ovs-dpdk-tgen-trex-txrx-ptp-lat-intel-11' "${PRESUBMIT_FILE}"
grep -Fq -- 'name: pull-ci-openshift-eng-ocp-qe-perfscale-ci-main-metal-nfv-e2e-x86-nfv-e2e-ovs-dpdk-tgen-trex-txrx-ptp-lat-intel-11' "${PRESUBMIT_FILE}"
grep -Fq -- 'rerun_command: /test metal-nfv-e2e-x86-nfv-e2e-ovs-dpdk-tgen-trex-txrx-ptp-lat-intel-11' "${PRESUBMIT_FILE}"
grep -Fq -- '--target=nfv-e2e-ovs-dpdk-tgen-trex-txrx-ptp-lat-intel-11' "${PRESUBMIT_FILE}"
grep -Fq -- 'metal-nfv-e2e-x86-nfv-e2e-ovs-dpdk-tgen-trex-txrx-ptp-lat-intel-11|remaining-required' "${PRESUBMIT_FILE}"
grep -Fq -- 'as: nfv-e2e-sriov-crucible-small-frames-intel-11' "${CONFIG_FILE}"
grep -Fq -- 'ref: openshift-qe-rhoso-nfv-e2e-lifecycle' "${CONFIG_FILE}"
[[ "$(grep -Fc -- '- ref: openshift-qe-rhoso-nfv-e2e-lifecycle' "${CONFIG_FILE}")" == 3 ]]
grep -Fq -- 'ref: openshift-qe-rhoso-nfv-e2e-crucible' "${CONFIG_FILE}"
grep -Fq -- 'FRAME_SIZES: 64,128,256,512' "${CONFIG_FILE}"
grep -Fq -- 'TIMEOUT_CRUCIBLE: "25200"' "${CONFIG_FILE}"
grep -Fq -- 'context: ci/prow/metal-nfv-e2e-x86-nfv-e2e-sriov-crucible-small-frames-intel-11' "${PRESUBMIT_FILE}"
grep -Fq -- 'name: pull-ci-openshift-eng-ocp-qe-perfscale-ci-main-metal-nfv-e2e-x86-nfv-e2e-sriov-crucible-small-frames-intel-11' "${PRESUBMIT_FILE}"
grep -Fq -- 'rerun_command: /test metal-nfv-e2e-x86-nfv-e2e-sriov-crucible-small-frames-intel-11' "${PRESUBMIT_FILE}"
grep -Fq -- '--target=nfv-e2e-sriov-crucible-small-frames-intel-11' "${PRESUBMIT_FILE}"
grep -Fq -- 'metal-nfv-e2e-x86-nfv-e2e-sriov-crucible-small-frames-intel-11|remaining-required' "${PRESUBMIT_FILE}"
mkdir -p "${WORK_DIR}/deployment-shared" "${WORK_DIR}/crucible-shared"
SHARED_DIR="${WORK_DIR}/deployment-shared" bash "${COMMANDS}" >/dev/null
SHARED_DIR="${WORK_DIR}/crucible-shared" bash "${COMMANDS}" >/dev/null
export ADAPTER_ARGS="${WORK_DIR}/adapter-args"
provider_env="${WORK_DIR}/provider-env"
printf '%s\n' "${FAKE_PROVIDER_DEFINITION}" >"${provider_env}"
export BASH_ENV="${provider_env}"
BUILD_ID=build-deploy \
SCENARIO=sriov \
EDPM_HOST=nfv-intel-11 \
SHARED_DIR="${WORK_DIR}/deployment-shared" \
BASH_ENV="${provider_env}" \
bash "${REPO_ROOT}/ci-operator/step-registry/openshift-qe/rhoso/nfv-e2e/run/openshift-qe-rhoso-nfv-e2e-run-commands.sh"
deployment_args=$(<"${ADAPTER_ARGS}")
[[ "${deployment_args}" == *deployment* ]]
[[ "${deployment_args}" == *SCENARIO=sriov* ]]
[[ "${deployment_args}" == *wait_timeout=42000* ]]
[[ "${deployment_args}" == *'E2E_EXTRA=--skip-crucible\ --edpm-host\ nfv-intel-11'* ]]

wait_status=0
FAKE_WAIT_FAILURE=1 BUILD_ID=build-deploy-fail SCENARIO=sriov EDPM_HOST=nfv-intel-11 \
  SHARED_DIR="${WORK_DIR}/deployment-shared" \
  bash "${REPO_ROOT}/ci-operator/step-registry/openshift-qe/rhoso/nfv-e2e/run/openshift-qe-rhoso-nfv-e2e-run-commands.sh" || wait_status=$?
[[ "${wait_status}" == 17 ]] || {
  printf 'lifecycle_wait returned %s, want 17\n' "${wait_status}" >&2
  exit 1
}

cancel_file="${WORK_DIR}/adapter-cancelled"
FAKE_WAIT_BLOCK=true FAKE_CANCEL_FILE="${cancel_file}" BUILD_ID=build-deploy-signal \
SCENARIO=sriov EDPM_HOST=nfv-intel-11 SHARED_DIR="${WORK_DIR}/deployment-shared" \
  bash "${REPO_ROOT}/ci-operator/step-registry/openshift-qe/rhoso/nfv-e2e/run/openshift-qe-rhoso-nfv-e2e-run-commands.sh" &
adapter_pid=$!
sleep 1
kill -TERM "${adapter_pid}"
signal_status=0
wait "${adapter_pid}" || signal_status=$?
[[ "${signal_status}" == 1 ]] || {
  printf 'signal-driven lifecycle_wait returned %s, want 1\n' "${signal_status}" >&2
  exit 1
}
[[ -f "${cancel_file}" ]]
signal_artifacts=( "${ARTIFACT_DIR}"/nfv-e2e-lifecycle-deployment-build-deploy-signal-*.txt )
[[ -s "${signal_artifacts[0]}" ]]
signal_base="${signal_artifacts[0]%.txt}"
[[ -s "${signal_base}-workload.log" && -s "${signal_base}-supervisor.log" ]]

for signal in TERM INT HUP; do
  crucible_cancel_file="${WORK_DIR}/crucible-cancelled-${signal}"
  if [[ "$signal" == INT ]]; then
    signal_pid_file="${WORK_DIR}/crucible-pid-${signal}"
    signal_sent_file="${WORK_DIR}/crucible-signal-sent-${signal}"
    FAKE_WAIT_BLOCK=true FAKE_CANCEL_FILE="${crucible_cancel_file}" \
    FAKE_SIGNAL="$signal" FAKE_SIGNAL_PID_FILE="${signal_pid_file}" \
    FAKE_SIGNAL_SENT_FILE="${signal_sent_file}" BUILD_ID="build-crucible-${signal}" \
    SCENARIO=sriov TIMEOUT_CRUCIBLE=25200 EDPM_HOST=nfv-intel-11 FRAME_SIZES=64,128,256,512 \
    SHARED_DIR="${WORK_DIR}/crucible-shared" \
    bash "${REPO_ROOT}/ci-operator/step-registry/openshift-qe/rhoso/nfv-e2e/crucible/openshift-qe-rhoso-nfv-e2e-crucible-commands.sh" &
    crucible_pid=$!
    printf '%s\n' "$crucible_pid" >"${signal_pid_file}"
  else
    FAKE_WAIT_BLOCK=true FAKE_CANCEL_FILE="${crucible_cancel_file}" BUILD_ID="build-crucible-${signal}" \
    SCENARIO=sriov TIMEOUT_CRUCIBLE=25200 EDPM_HOST=nfv-intel-11 FRAME_SIZES=64,128,256,512 \
    SHARED_DIR="${WORK_DIR}/crucible-shared" \
    bash "${REPO_ROOT}/ci-operator/step-registry/openshift-qe/rhoso/nfv-e2e/crucible/openshift-qe-rhoso-nfv-e2e-crucible-commands.sh" &
    crucible_pid=$!
    sleep 1
    kill "-${signal}" "$crucible_pid"
  fi
  signal_status=0
  wait "$crucible_pid" || signal_status=$?
  printf 'signal=%s status=%s cancelled=%s\n' "$signal" "$signal_status" \
    "$([[ -f "$crucible_cancel_file" ]] && printf true || printf false)" >&2
  [[ "$signal_status" == 1 && -f "$crucible_cancel_file" ]]
  crucible_artifacts=( "${ARTIFACT_DIR}"/nfv-e2e-lifecycle-crucible-build-crucible-${signal}-*.txt )
  [[ -s "${crucible_artifacts[0]}" ]]
  crucible_base="${crucible_artifacts[0]%.txt}"
  [[ -s "${crucible_base}-workload.log" && -s "${crucible_base}-supervisor.log" ]]
done
BUILD_ID=build-crucible \
SCENARIO=sriov \
TIMEOUT_CRUCIBLE=25200 \
EDPM_HOST=nfv-intel-11 \
FRAME_SIZES=64,128,256,512 \
SHARED_DIR="${WORK_DIR}/crucible-shared" \
bash "${REPO_ROOT}/ci-operator/step-registry/openshift-qe/rhoso/nfv-e2e/crucible/openshift-qe-rhoso-nfv-e2e-crucible-commands.sh"
crucible_args=$(<"${ADAPTER_ARGS}")
[[ "${crucible_args}" == *crucible* ]]
[[ "${crucible_args}" == *'E2E_EXTRA=--timeout-crucible\ 25200'* ]]
[[ "${crucible_args}" == *'--frame-sizes\ 64\,128\,256\,512'* ]]
[[ "${crucible_args}" == *wait_timeout=26400* ]]

printf 'lifecycle harness passed\n'

