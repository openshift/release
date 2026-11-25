#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

: "${SCENARIO:?SCENARIO must be set}"
: "${TIMEOUT_CRUCIBLE:?TIMEOUT_CRUCIBLE must be set}"
: "${EDPM_HOST:?EDPM_HOST must be set}"
: "${FRAME_SIZES:?FRAME_SIZES must be set}"
: "${CLUSTER_PROFILE_DIR:?CLUSTER_PROFILE_DIR must be set}"

[[ "${SCENARIO}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'SCENARIO contains unsafe characters' >&2; exit 1; }
[[ "${EDPM_HOST}" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo 'EDPM_HOST contains unsafe characters' >&2; exit 1; }
[[ "${FRAME_SIZES}" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo 'FRAME_SIZES contains unsafe characters' >&2; exit 1; }
[[ "${TIMEOUT_CRUCIBLE}" =~ ^[1-9][0-9]*$ ]] || { echo 'TIMEOUT_CRUCIBLE must be a positive decimal integer' >&2; exit 1; }

mounted_identity="${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key"
[[ -f "${mounted_identity}" && -r "${mounted_identity}" ]] ||
  { echo 'approved SSH identity is unavailable' >&2; exit 1; }
identity=''
if ! identity=$(mktemp); then
  echo 'approved SSH identity could not be prepared' >&2
  exit 1
fi
trap 'rm -f -- "${identity}"' EXIT
if ! cp -- "${mounted_identity}" "${identity}" || ! chmod 600 -- "${identity}"; then
  echo 'approved SSH identity could not be prepared' >&2
  exit 1
fi
[[ -O "${identity}" ]] ||
  { echo 'approved SSH identity has an unexpected owner' >&2; exit 1; }
[[ "$(stat -c '%a' -- "${identity}")" =~ ^[0-7]00$ ]] ||
  { echo 'approved SSH identity permissions are too broad' >&2; exit 1; }
[[ -r "${CLUSTER_PROFILE_DIR}/address" && -r "${CLUSTER_PROFILE_DIR}/bastion" ]] ||
  { echo 'required SSH endpoints are unavailable' >&2; exit 1; }

SSH_ARGS=(
  -i "${identity}"
  -o IdentitiesOnly=yes
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=60
  -o ServerAliveCountMax=240
  -o ConnectTimeout=30
)
jumphost=$(<"${CLUSTER_PROFILE_DIR}/address")
bastion=$(<"${CLUSTER_PROFILE_DIR}/bastion")
[[ "${jumphost}" =~ ^[A-Za-z0-9._:-]+$ && "${bastion}" =~ ^[A-Za-z0-9._:-]+$ ]] ||
  { echo 'SSH host contains unsafe characters' >&2; exit 1; }

# shellcheck disable=SC2087
ssh "${SSH_ARGS[@]}" root@"${jumphost}" bash -s -- "${bastion}" "${SCENARIO}" "${TIMEOUT_CRUCIBLE}" "${EDPM_HOST}" "${FRAME_SIZES}" <<'REMOTE'
set -o errexit
set -o nounset
set -o pipefail

bastion="$1"
scenario="$2"
timeout_crucible="$3"
edpm_host="$4"
frame_sizes="$5"

workspace=/home/zuul/netperf-rhoso18-nfv-e2e-validation
log_file=/tmp/nfv-e2e-crucible.$$.log
SSH_ARGS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=60
  -o ServerAliveCountMax=240
  -o ConnectTimeout=30
)

# shellcheck disable=SC2087
ssh "${SSH_ARGS[@]}" zuul@"${bastion}" bash -s -- "${scenario}" "${timeout_crucible}" "${edpm_host}" "${frame_sizes}" "${workspace}" "${log_file}" <<'INNER'
set -o errexit
set -o nounset
set -o pipefail

scenario="$1"
timeout_crucible="$2"
edpm_host="$3"
frame_sizes="$4"
workspace="$5"
log_file="$6"
workload_pid=''
termination_complete=0
alarm_pid=''
pid_file="${log_file}.pid"
timeout_flag="${log_file}.timeout"

terminate_workload() {
  # The workload runs in its own session, so only the leader PID it publishes
  # through pid_file owns the killable process group; the launcher PID lives
  # in this shell's group and must never be group-signalled.
  local leader=''
  leader=$(cat -- "${pid_file}" 2>/dev/null || :)
  if [[ -n "${leader}" ]] && kill -0 -- "-${leader}" 2>/dev/null; then
    kill -TERM -- "-${leader}" 2>/dev/null || true
    for ((i = 1; i <= 60; i++)); do
      kill -0 -- "-${leader}" 2>/dev/null || { termination_complete=1; return 0; }
      sleep 1
    done
    kill -KILL -- "-${leader}" 2>/dev/null || true
    for ((i = 1; i <= 5; i++)); do
      kill -0 -- "-${leader}" 2>/dev/null || { termination_complete=1; return 0; }
      sleep 1
    done
    echo 'NFV_E2E_TERMINATION=failed' >&2
    return 1
  fi
  # The workload never published a leader: bound the launcher process alone.
  if [[ -n "${workload_pid}" ]] && kill -0 "${workload_pid}" 2>/dev/null; then
    kill -TERM "${workload_pid}" 2>/dev/null || true
    for ((i = 1; i <= 10; i++)); do
      kill -0 "${workload_pid}" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "${workload_pid}" 2>/dev/null || true
  fi
  termination_complete=1
  return 0
}

cleanup() {
  status=$?
  trap - EXIT HUP TERM INT
  if [[ -n "${alarm_pid}" ]]; then
    kill -KILL "${alarm_pid}" 2>/dev/null || true
  fi
  if (( termination_complete == 0 )); then
    terminate_workload || status=1
  fi
  rm -f -- "${log_file}" "${pid_file}" "${timeout_flag}" || true
  exit "${status}"
}

on_signal() {
  trap - HUP TERM INT
  exit 143
}
trap cleanup EXIT
trap on_signal HUP TERM INT

umask 077
tmp_log=''
if ! tmp_log=$(mktemp "${log_file}.XXXXXX") ||
  ! chmod 600 -- "${tmp_log}" ||
  ! mv -T -- "${tmp_log}" "${log_file}"; then
  [[ -z "${tmp_log}" ]] || rm -f -- "${tmp_log}"
  echo 'NFV_E2E_LOG_SETUP=failed'
  exit 1
fi
rm -f -- "${pid_file}" "${timeout_flag}" || true
if ! cd -- "${workspace}"; then
  echo 'NFV_E2E_WORKSPACE=unavailable'
  exit 1
fi

# --fork --wait makes setsid always fork and always wait for the workload, so
# $! stays alive exactly as long as the workload and propagates its exit
# status.  A bare setsid forks only when the caller is a process-group
# leader, which leaves the tracked PID's meaning dependent on context.
setsid --fork --wait bash -s -- "${scenario}" "${timeout_crucible}" "${edpm_host}" "${frame_sizes}" "${log_file}" "${pid_file}" <<'WORKLOAD' &
set -o errexit
set -o nounset
set -o pipefail

scenario="$1"
timeout_crucible="$2"
edpm_host="$3"
frame_sizes="$4"
log_file="$5"
pid_file="$6"

# The workload bash is the session leader setsid created, so $$ is also the
# process-group ID every watchdog signal must target.
printf '%s\n' "$$" > "${pid_file}"

set +o errexit
make e2e-crucible \
  "SCENARIO=${scenario}" \
  LAB_ENV=~/nfv-e2e/lab-init.env \
  E2E_EXTRA="--timeout-crucible ${timeout_crucible} --edpm-host ${edpm_host} --frame-sizes ${frame_sizes}" \
  2>&1 |
  sed -E \
    -e 's/(Bearer[[:space:]]+)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/((password|token|secret|authorization|credential|private[_-]?key)[[:space:]]*[:=][[:space:]]*)"[^"]*"/\1[REDACTED]/Ig' \
    -e "s/((password|token|secret|authorization|credential|private[_-]?key)[[:space:]]*[:=][[:space:]]*)'[^']*'/\1[REDACTED]/Ig" \
    -e 's/((password|token|secret|authorization|credential|private[_-]?key)[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' |
  tee "${log_file}"
pipeline_status=("${PIPESTATUS[@]}")
set -o errexit
workload_status="${pipeline_status[0]}"
filter_status="${pipeline_status[1]}"
capture_status="${pipeline_status[2]}"
printf 'NFV_E2E_TERMINAL=1\nNFV_E2E_WORKLOAD_EXIT=%s\nNFV_E2E_FILTER_EXIT=%s\nNFV_E2E_CAPTURE_EXIT=%s\n' \
  "${workload_status}" "${filter_status}" "${capture_status}"
if (( filter_status != 0 )); then
  exit "${filter_status}"
fi
if (( capture_status != 0 )); then
  exit "${capture_status}"
fi
exit "${workload_status}"
WORKLOAD
workload_pid=$!

# Independent deadline alarm: a separate process enforces TIMEOUT_CRUCIBLE so
# a stalled workload pipeline, a survivor holding the output pipe, or a
# wedged wrapper loop cannot keep this step alive past its bound.  Output and
# error are discarded so neither the alarm nor its sleep can hold the SSH
# session channel open.
(
  sleep "${timeout_crucible}"
  # If the wrapper is gone the job already ended; acting now could hit a
  # reused PID, so stand down.
  if [[ ${PPID} -eq 1 ]]; then
    exit 0
  fi
  : > "${timeout_flag}"
  leader=$(cat -- "${pid_file}" 2>/dev/null || :)
  if [[ -n "${leader}" ]]; then
    kill -TERM -- "-${leader}" 2>/dev/null || true
    for ((i = 1; i <= 65; i++)); do
      kill -0 -- "-${leader}" 2>/dev/null || break
      sleep 1
    done
    kill -KILL -- "-${leader}" 2>/dev/null || true
  else
    # No published leader: bound the launcher so the wrapper's wait returns.
    kill -TERM "${workload_pid}" 2>/dev/null || true
  fi
) >/dev/null 2>&1 &
alarm_pid=$!

set +o errexit
wait "${workload_pid}"
workload_status=$?
# KILL, not TERM: bash defers TERM while the alarm waits on its sleep, but
# KILL reaps the alarm at once and leaves only an fd-less orphan sleep.
kill -KILL "${alarm_pid}" 2>/dev/null || true
wait "${alarm_pid}" 2>/dev/null || true
set -o errexit

if [[ -f "${timeout_flag}" ]]; then
  printf 'NFV_E2E_TERMINAL=1\nNFV_E2E_WORKLOAD_EXIT=124\nNFV_E2E_FILTER_EXIT=unknown\nNFV_E2E_CAPTURE_EXIT=unknown\n'
  exit 124
fi
exit "${workload_status}"
INNER
REMOTE
