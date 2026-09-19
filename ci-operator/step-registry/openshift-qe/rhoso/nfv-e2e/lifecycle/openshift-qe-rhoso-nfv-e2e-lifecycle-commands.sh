#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

: "${SHARED_DIR:?SHARED_DIR must be set}"

helper="${SHARED_DIR}/openshift-qe-rhoso-nfv-e2e-lifecycle.sh"
mkdir -p "${SHARED_DIR}"
cat >"${helper}" <<'LIFECYCLE_HELPER'
#!/bin/bash
# Shared NFV E2E run lifecycle. Source this file; it deliberately does not set
# shell options so that it cannot change the caller's error-handling policy.

: "${SHARED_DIR:?SHARED_DIR must be set}"

LIFECYCLE_LEASE_SECONDS="${LIFECYCLE_LEASE_SECONDS:-300}"
LIFECYCLE_CLEANUP_GRACE_SECONDS="${LIFECYCLE_CLEANUP_GRACE_SECONDS:-600}"
LIFECYCLE_POLL_SECONDS="${LIFECYCLE_POLL_SECONDS:-5}"
LIFECYCLE_WAIT_TIMEOUT_SECONDS="${LIFECYCLE_WAIT_TIMEOUT_SECONDS:-43200}"
LIFECYCLE_SUPERVISOR_PROGRESS_TIMEOUT_SECONDS="${LIFECYCLE_SUPERVISOR_PROGRESS_TIMEOUT_SECONDS:-30}"
LIFECYCLE_RUN_ID="${LIFECYCLE_RUN_ID:-}"
LIFECYCLE_RUN_DIR="${LIFECYCLE_RUN_DIR:-}"
LIFECYCLE_KIND="${LIFECYCLE_KIND:-}"
LIFECYCLE_LAST_STATE="${LIFECYCLE_LAST_STATE:-}"
LIFECYCLE_RECONNECT_ATTEMPTS="${LIFECYCLE_RECONNECT_ATTEMPTS:-3}"
LIFECYCLE_RECONNECT_DELAY_SECONDS="${LIFECYCLE_RECONNECT_DELAY_SECONDS:-1}"
LIFECYCLE_OPERATION_TIMEOUT_SECONDS="${LIFECYCLE_OPERATION_TIMEOUT_SECONDS:-30}"
LIFECYCLE_SSH_SERVER_ALIVE_INTERVAL="${LIFECYCLE_SSH_SERVER_ALIVE_INTERVAL:-60}"
LIFECYCLE_SSH_SERVER_ALIVE_COUNT_MAX="${LIFECYCLE_SSH_SERVER_ALIVE_COUNT_MAX:-240}"
LIFECYCLE_KNOWN_HOSTS="${LIFECYCLE_KNOWN_HOSTS:-}"
LIFECYCLE_CONTROLLER_USER="${LIFECYCLE_CONTROLLER_USER:-}"
LIFECYCLE_WORKLOAD_USER="${LIFECYCLE_WORKLOAD_USER:-zuul}"
LIFECYCLE_CGROUP_ROOT="${LIFECYCLE_CGROUP_ROOT:-/sys/fs/cgroup}"
LIFECYCLE_STATE_ROOT="${LIFECYCLE_STATE_ROOT:-}"
LIFECYCLE_EXPECTED_MAKEFILE="${LIFECYCLE_EXPECTED_MAKEFILE:-Makefile}"
LIFECYCLE_LAB_ENV="${LIFECYCLE_LAB_ENV:-}"
LIFECYCLE_RECORD_VERIFIER="${LIFECYCLE_RECORD_VERIFIER:-}"
LIFECYCLE_OWNER_EPOCH="${LIFECYCLE_OWNER_EPOCH:-}"
LIFECYCLE_RECORD_SEQUENCE="${LIFECYCLE_RECORD_SEQUENCE:-}"

_lifecycle_die() { printf 'NFV lifecycle: %s\n' "$*" >&2; return 1; }
_lifecycle_now() { date +%s; }
_lifecycle_valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }
_lifecycle_valid_kind() { [[ "$1" == deployment || "$1" == crucible ]]; }
_lifecycle_valid_authority() {
  if declare -F lifecycle_remote_provider >/dev/null 2>&1 ||
    [[ "${LIFECYCLE_LOCAL_REMOTE:-false}" == true ]]; then
    return 0
  fi
  [[ "$LIFECYCLE_CONTROLLER_USER" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] ||
    { _lifecycle_die 'distinct lifecycle controller identity is required'; return 1; }
  [[ "$LIFECYCLE_WORKLOAD_USER" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] ||
    { _lifecycle_die 'invalid lifecycle workload identity'; return 1; }
  [[ "$LIFECYCLE_CONTROLLER_USER" != "$LIFECYCLE_WORKLOAD_USER" ]] ||
    { _lifecycle_die 'lifecycle controller and workload identities must differ'; return 1; }
}

_lifecycle_valid_workspace() {
  [[ "$1" == /* && "$1" != *' '* && "$1" != *$'\t'* && "$1" != *$'\n'* && "$1" != *'..'* && "$1" =~ ^/[A-Za-z0-9._/-]+$ ]]
}
_lifecycle_nonce() {
  od -An -N12 -tx1 /dev/urandom | tr -d ' \n'
}
_lifecycle_valid_number() {
  local value="$1"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
  (( ${#value} < 7 )) && return 0
  (( ${#value} == 7 )) && [[ "$value" < 1000001 ]]
}
_lifecycle_validate_budget() {
  _lifecycle_valid_number "$LIFECYCLE_LEASE_SECONDS" ||
    { _lifecycle_die 'lease must be a positive integer <= 1000000'; return 1; }
  _lifecycle_valid_number "$LIFECYCLE_CLEANUP_GRACE_SECONDS" ||
    { _lifecycle_die 'cleanup grace must be a positive integer <= 1000000'; return 1; }
  _lifecycle_valid_number "$LIFECYCLE_POLL_SECONDS" ||
    { _lifecycle_die 'poll interval must be a positive integer <= 1000000'; return 1; }
  _lifecycle_valid_number "$LIFECYCLE_WAIT_TIMEOUT_SECONDS" ||
    { _lifecycle_die 'wait timeout must be a positive integer <= 1000000'; return 1; }
  _lifecycle_valid_number "$LIFECYCLE_SUPERVISOR_PROGRESS_TIMEOUT_SECONDS" ||
    { _lifecycle_die 'supervisor progress timeout must be a positive integer <= 1000000'; return 1; }
  _lifecycle_valid_number "$LIFECYCLE_RECONNECT_ATTEMPTS" ||
    { _lifecycle_die 'reconnect attempts must be a positive integer <= 1000000'; return 1; }
  _lifecycle_valid_number "$LIFECYCLE_RECONNECT_DELAY_SECONDS" ||
    { _lifecycle_die 'reconnect delay must be a positive integer <= 1000000'; return 1; }
  _lifecycle_valid_number "$LIFECYCLE_OPERATION_TIMEOUT_SECONDS" ||
    { _lifecycle_die 'operation timeout must be a positive integer <= 1000000'; return 1; }
  _lifecycle_valid_number "$LIFECYCLE_SSH_SERVER_ALIVE_INTERVAL" ||
    { _lifecycle_die 'SSH keepalive interval must be a positive integer <= 1000000'; return 1; }
  _lifecycle_valid_number "$LIFECYCLE_SSH_SERVER_ALIVE_COUNT_MAX" ||
    { _lifecycle_die 'SSH keepalive count must be a positive integer <= 1000000'; return 1; }
  (( LIFECYCLE_POLL_SECONDS < LIFECYCLE_LEASE_SECONDS )) || { _lifecycle_die 'poll interval must be shorter than lease'; return 1; }
  (( LIFECYCLE_OPERATION_TIMEOUT_SECONDS < LIFECYCLE_LEASE_SECONDS )) || { _lifecycle_die 'operation timeout must be shorter than lease'; return 1; }
  local retry_budget=$(( LIFECYCLE_RECONNECT_ATTEMPTS * LIFECYCLE_OPERATION_TIMEOUT_SECONDS +
    (LIFECYCLE_RECONNECT_ATTEMPTS - 1) * LIFECYCLE_RECONNECT_DELAY_SECONDS ))
  (( retry_budget < LIFECYCLE_LEASE_SECONDS )) ||
    { _lifecycle_die 'retry budget must be shorter than lease'; return 1; }
  (( LIFECYCLE_WAIT_TIMEOUT_SECONDS >= retry_budget )) ||
    { _lifecycle_die 'wait timeout must cover the complete retry budget'; return 1; }
}

# Tests may provide a deterministic provider. Production uses the two-hop SSH
# provider below. Keeping this seam explicit makes the protocol testable without
# pretending a local shell is a remote bastion.
lifecycle_remote() {
  if declare -F lifecycle_remote_provider >/dev/null 2>&1; then
    lifecycle_remote_provider "$@"
  elif [[ "${LIFECYCLE_LOCAL_REMOTE:-false}" == true ]]; then
    _lifecycle_remote_agent local "$@"
  else
    _lifecycle_ssh_remote "$@"
  fi
}
_lifecycle_remote_retry() {
  local destination='' attempts=0 output retry_file deadline="${LIFECYCLE_RETRY_DEADLINE:-}"
  local saved_timeout="${LIFECYCLE_OPERATION_TIMEOUT_SECONDS}" remaining last_status=1
  if [[ "${1:-}" == --file ]]; then
    destination="${2:?retry destination is required}"
    shift 2
  fi
  if [[ -n "$destination" ]]; then
    retry_file=$(mktemp "${destination}.retry.XXXXXX") || return 1
  else
    retry_file=$(mktemp "${SHARED_DIR}/.nfv-e2e-lifecycle-retry.XXXXXX") || return 1
  fi
  while (( attempts < LIFECYCLE_RECONNECT_ATTEMPTS )); do
    if [[ -n "$deadline" ]]; then
      remaining=$(( deadline - $(_lifecycle_now) ))
      if (( remaining <= 0 )); then
        rm -f "$retry_file"
        LIFECYCLE_OPERATION_TIMEOUT_SECONDS="$saved_timeout"
        return "$last_status"
      fi
      if (( remaining < saved_timeout )); then
        LIFECYCLE_OPERATION_TIMEOUT_SECONDS="$remaining"
      else
        LIFECYCLE_OPERATION_TIMEOUT_SECONDS="$saved_timeout"
      fi
    fi
    if lifecycle_remote "$@" >"$retry_file"; then
      if [[ -n "$destination" ]]; then
        mv -f "$retry_file" "$destination" || {
          rm -f "$retry_file"
          LIFECYCLE_OPERATION_TIMEOUT_SECONDS="$saved_timeout"
          return 1
        }
      else
        output=$(<"$retry_file")
      fi
      rm -f "$retry_file"
      LIFECYCLE_OPERATION_TIMEOUT_SECONDS="$saved_timeout"
      [[ -n "$destination" ]] || printf '%s\n' "$output"
      return 0
    else
      last_status=$?
      LIFECYCLE_LAST_REMOTE_STATUS="$last_status"
      export LIFECYCLE_LAST_REMOTE_STATUS
    fi
    attempts=$((attempts + 1))
    if (( attempts < LIFECYCLE_RECONNECT_ATTEMPTS && LIFECYCLE_RECONNECT_DELAY_SECONDS > 0 )); then
      if [[ -n "$deadline" ]]; then
        remaining=$(( deadline - $(_lifecycle_now) ))
        if (( remaining <= 0 )); then
          rm -f "$retry_file"
          LIFECYCLE_OPERATION_TIMEOUT_SECONDS="$saved_timeout"
          return "$last_status"
        fi
        sleep "$(( LIFECYCLE_RECONNECT_DELAY_SECONDS < remaining ? LIFECYCLE_RECONNECT_DELAY_SECONDS : remaining ))"
      else
        sleep "$LIFECYCLE_RECONNECT_DELAY_SECONDS"
      fi
    fi
  done
  rm -f "$retry_file"
  LIFECYCLE_OPERATION_TIMEOUT_SECONDS="$saved_timeout"
  return "$last_status"
}

_lifecycle_ssh_remote() {
  local op="$1"; shift
  local jumphost="${LIFECYCLE_JUMPHOST:-}" bastion="${LIFECYCLE_BASTION:-}"
  if [[ -z "$jumphost" || -z "$bastion" ]]; then
    local profile_dir="${CLUSTER_PROFILE_DIR:-}"
    [[ -n "$profile_dir" && -d "$profile_dir" &&
      -f "$profile_dir/address" && -f "$profile_dir/bastion" ]] || {
      _lifecycle_die 'jumphost and bastion are required'
      return 1
    }
    jumphost=$(<"$profile_dir/address") || return 1
    bastion=$(<"$profile_dir/bastion") || return 1
  fi
  [[ "$jumphost" =~ ^[A-Za-z0-9._:-]+$ &&
    "$bastion" =~ ^[A-Za-z0-9._:-]+$ ]] || {
    _lifecycle_die 'unsafe SSH host'
    return 1
  }
  local known_hosts="${LIFECYCLE_KNOWN_HOSTS:-}" profile_real known_hosts_real
  if [[ -n "$known_hosts" ]]; then
    [[ -n "${CLUSTER_PROFILE_DIR:-}" && "$known_hosts" != *'..'* &&
      -d "${CLUSTER_PROFILE_DIR}" && ! -L "$known_hosts" && -f "$known_hosts" ]] || {
      _lifecycle_die 'known-hosts file must be a regular cluster-profile file'
      return 1
    }
    profile_real=$(readlink -f -- "$CLUSTER_PROFILE_DIR") || {
      _lifecycle_die 'cluster profile path cannot be resolved'
      return 1
    }
    known_hosts_real=$(readlink -f -- "$known_hosts") || {
      _lifecycle_die 'known-hosts path cannot be resolved'
      return 1
    }
    [[ "$known_hosts_real" == "$profile_real/"* ]] || {
      _lifecycle_die 'known-hosts file must stay inside cluster profile'
      return 1
    }
  fi
  local key="${CLUSTER_PROFILE_DIR:-}/jh_priv_ssh_key"
  local host_key_mode=no host_key_file=/dev/null
  if [[ -n "$known_hosts" ]]; then
    host_key_mode=yes
    host_key_file="$known_hosts"
  fi
  local -a jh_args=(-o "StrictHostKeyChecking=${host_key_mode}"
    -o "UserKnownHostsFile=${host_key_file}" -o LogLevel=ERROR -o ConnectTimeout=30
    -o "ServerAliveInterval=${LIFECYCLE_SSH_SERVER_ALIVE_INTERVAL}"
    -o "ServerAliveCountMax=${LIFECYCLE_SSH_SERVER_ALIVE_COUNT_MAX}")
  [[ -f "$key" ]] && jh_args+=(-i "$key")
  local agent_payload remote_known_hosts=
  agent_payload=$({ declare -f _lifecycle_remote_agent; printf '%s\n' '_lifecycle_remote_agent "$@"'; } | base64 | tr -d '\n')
  if [[ -n "$known_hosts" ]]; then
    remote_known_hosts=$(
      base64 <"$known_hosts" |
        timeout "$LIFECYCLE_OPERATION_TIMEOUT_SECONDS" \
          ssh "${jh_args[@]}" root@"${jumphost}" \
          'umask 077; remote_known_hosts=$(mktemp /tmp/nfv-e2e-known-hosts.XXXXXX) || exit 1; chmod 600 "$remote_known_hosts"; base64 -d >"$remote_known_hosts" || { rm -f "$remote_known_hosts"; exit 1; }; printf "%s\n" "$remote_known_hosts"'
    ) || return 1
    [[ "$remote_known_hosts" == /tmp/nfv-e2e-known-hosts.* ]] || return 1
  fi
  timeout "$LIFECYCLE_OPERATION_TIMEOUT_SECONDS" \
    ssh "${jh_args[@]}" root@"${jumphost}" bash -s -- "$bastion" "$op" "$agent_payload" "$remote_known_hosts" \
      "$LIFECYCLE_SSH_SERVER_ALIVE_INTERVAL" "$LIFECYCLE_SSH_SERVER_ALIVE_COUNT_MAX" \
      "$LIFECYCLE_OPERATION_TIMEOUT_SECONDS" "$LIFECYCLE_SUPERVISOR_PROGRESS_TIMEOUT_SECONDS" \
      "$LIFECYCLE_CONTROLLER_USER" "$LIFECYCLE_WORKLOAD_USER" "$LIFECYCLE_CGROUP_ROOT" \
      "$LIFECYCLE_EXPECTED_MAKEFILE" "$LIFECYCLE_LAB_ENV" "$@" <<'JUMP_SCRIPT'
set -o errexit
set -o nounset
set -o pipefail
bastion="$1"; op="$2"; payload="$3"; remote_known_hosts="$4"; alive_interval="$5"; alive_count="$6"; operation_timeout="$7"; progress_timeout="$8"; controller_user="$9"; workload_user="${10}"; cgroup_root="${11}"; expected_makefile="${12}"; lab_env="${13}"; shift 13
cleanup_inner_known_hosts() {
  [[ -z "$remote_known_hosts" ]] || rm -f "$remote_known_hosts"
}
trap cleanup_inner_known_hosts EXIT
host_key_mode=no
host_key_file=/dev/null
if [[ -n "$remote_known_hosts" ]]; then
  host_key_mode=yes
  host_key_file="$remote_known_hosts"
fi
ssh_args=(-o "StrictHostKeyChecking=${host_key_mode}"
  -o "UserKnownHostsFile=${host_key_file}" -o LogLevel=ERROR -o ConnectTimeout=30
  -o "ServerAliveInterval=${alive_interval}" -o "ServerAliveCountMax=${alive_count}")
export LIFECYCLE_SUPERVISOR_PROGRESS_TIMEOUT_SECONDS="$progress_timeout"
export LIFECYCLE_CONTROLLER_USER="$controller_user" LIFECYCLE_WORKLOAD_USER="$workload_user" \
  LIFECYCLE_CGROUP_ROOT="$cgroup_root" LIFECYCLE_EXPECTED_MAKEFILE="$expected_makefile" \
  LIFECYCLE_LAB_ENV="$lab_env"
printf '%s' "$payload" | base64 -d | timeout "$operation_timeout" \
  ssh "${ssh_args[@]}" zuul@"$bastion" bash -s -- "$bastion" "$op" "$@"
JUMP_SCRIPT
}

# This function is copied through the jumphost and executed as zuul on the
# account-wide process selector.
_lifecycle_remote_agent() {
  local bastion="$1" op="$2"; shift 2 || :
  local controller_user="${LIFECYCLE_CONTROLLER_USER:-}" workload_user="${LIFECYCLE_WORKLOAD_USER:-}"
  if [[ "$(id -un)" != "$controller_user" ]]; then
    [[ -n "$controller_user" && "$controller_user" != "$workload_user" ]] || return 78
    command -v sudo >/dev/null 2>&1 || return 78
    {
      declare -f _lifecycle_remote_agent
      printf '%s\n' '_lifecycle_remote_agent "$@"'
    } | sudo -n -u "$controller_user" env \
      LIFECYCLE_CONTROLLER_USER="$controller_user" \
      LIFECYCLE_WORKLOAD_USER="$workload_user" \
      LIFECYCLE_CGROUP_ROOT="${LIFECYCLE_CGROUP_ROOT:-/sys/fs/cgroup}" \
      LIFECYCLE_EXPECTED_MAKEFILE="${LIFECYCLE_EXPECTED_MAKEFILE:-Makefile}" \
      LIFECYCLE_LAB_ENV="${LIFECYCLE_LAB_ENV:-}" \
      bash -s -- "$bastion" "$op" "$@"
    return $?
  fi
  local run_dir run_id kind build_id lease owner command_file supervisor_launcher
  local record_auth_enabled=false active_epoch='' active_sequence=''
  umask 077
  _read() { [[ -f "$1" && ! -L "$1" ]] && cat "$1" || :; }
  _record_tag() {
    local state="$1" workload_status="$2" workload_exit="$3" terminal_cause="$4" cleanup_status="$5" sequence="${6:-$active_sequence}"
    printf '%s' "$run_id|$capability|$sequence|$active_epoch|$state|$workload_status|$workload_exit|$terminal_cause|$cleanup_status" |
      sha256sum | cut -d' ' -f1
  }
  _record_mutation() {
    [[ "$record_auth_enabled" == true ]] || return 0
    local path="$1" value="$2" lock="${run_dir}/record.lock" sequence next tmp payload
    local tries=0
    while ! mkdir "$lock" 2>/dev/null; do
      tries=$((tries + 1))
      (( tries < 100 )) || return 1
      sleep 0.01
    done
    sequence=$(_read "${run_dir}/record.sequence")
    [[ "$sequence" =~ ^[0-9]+$ ]] || { rmdir "$lock" 2>/dev/null || :; return 1; }
    next=$((sequence + 1))
    payload=$(printf '%s' "$value" | base64 | tr -d '\n') || {
      rmdir "$lock" 2>/dev/null || :
      return 1
    }
    tmp="${run_dir}/record.${next}.mutation.tmp.$BASHPID"
    if ! printf 'run_id=%s sequence=%s owner_epoch=%s path=%s value=%s\n' \
      "$run_id" "$next" "$active_epoch" "${path##*/}" "$payload" >"$tmp"; then
      rm -f "$tmp"
      rmdir "$lock" 2>/dev/null || :
      return 1
    fi
    chmod 600 "$tmp" && mv -f "$tmp" "${run_dir}/record.${next}.mutation" &&
      printf '%s\n' "$next" >"${run_dir}/record.sequence.tmp.$BASHPID" &&
      mv -f "${run_dir}/record.sequence.tmp.$BASHPID" "${run_dir}/record.sequence"
    local rc=$?
    rm -f "$tmp" "${run_dir}/record.sequence.tmp.$BASHPID"
    rmdir "$lock" 2>/dev/null || :
    return "$rc"
  }
  _write() {
    local path="$1" value="$2" tmp
    [[ "$record_auth_enabled" != true || "$path" == "$run_dir"/record.* ||
      "$path" == "$run_dir"/auth_capability || "$path" == "$run_dir"/owner_epoch ||
      "$path" == "$run_dir"/record.sequence ]] || {
      [[ "$(_read "${run_dir}/owner_epoch")" == "$active_epoch" &&
        "$(_read "${run_dir}/terminal_published")" != true ]] || return 77
    }
    tmp="${path}.tmp.$BASHPID"
    printf '%s\n' "$value" >"$tmp" &&
      chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
    _record_mutation "$path" "$value"
  }
  _safe_path() { [[ "$1" == /* && "$1" != *'..'* && "$1" =~ ^/[A-Za-z0-9._/-]+$ ]]; }
  _verify_run() {
    local candidate="$1" expected_id="$2" expected_verifier="${3:-}" expected_epoch="${4:-}"
    _safe_path "$candidate" || return 64
    owner=$(id -un)
    [[ -d "$candidate" && ! -L "$candidate" &&
      "$(_read "$candidate/run_id")" == "$expected_id" &&
      "$(_read "$candidate/owner")" == "$owner" &&
      "$(_read "$candidate/controller_user")" == "$owner" &&
      -n "$expected_verifier" && "$(_read "$candidate/auth_capability")" == "$expected_verifier" ]] ||
      return 65
    active_epoch=$(_read "$candidate/owner_epoch")
    [[ "$active_epoch" =~ ^[1-9][0-9]*$ ]] || return 65
    [[ -z "$expected_epoch" || "$expected_epoch" == "$active_epoch" ]] || return 66
    active_sequence=$(_read "$candidate/record.sequence")
    [[ "$active_sequence" =~ ^[0-9]+$ ]] || return 65
    run_dir="$candidate"
    run_id="$expected_id"
    record_auth_enabled=true
  }
  _advance_epoch() {
    local lock="${run_dir}/owner-epoch.lock" current next tmp
    mkdir "$lock" 2>/dev/null || return 1
    current=$(_read "${run_dir}/owner_epoch")
    [[ "$current" =~ ^[1-9][0-9]*$ ]] || {
      rmdir "$lock" 2>/dev/null || :
      return 1
    }
    next=$((current + 1))
    tmp="${run_dir}/owner_epoch.tmp.$BASHPID"
    if ! printf '%s\n' "$next" >"$tmp" || ! chmod 600 "$tmp" ||
      ! mv -f "$tmp" "${run_dir}/owner_epoch"; then
      rm -f "$tmp"
      rmdir "$lock" 2>/dev/null || :
      return 1
    fi
    active_epoch="$next"
    _record_mutation "${run_dir}/owner_epoch" "$next" || {
      rmdir "$lock" 2>/dev/null || :
      return 1
    }
    rmdir "$lock" 2>/dev/null || return 1
  }
  _now() { date +%s; }
  _write_evidence() {
    local path="$1" pid="$2" pgid="$3" user="$4" state="$5" comm="$6" identity="$7"
    comm=${comm//[^A-Za-z0-9_.:-]/_}
    printf 'PID=%s PGID=%s OWNER=%s STATE=%s COMM=%s IDENTITY=%s\n' \
      "$pid" "$pgid" "$user" "$state" "$comm" "$identity" >>"$path"
  }
  _proc_identity() {
    local pid="$1" needle="NFV_E2E_RUN_ID=$run_id" value
    [[ -e "/proc/$pid" ]] || return 1
    [[ -r "/proc/$pid/environ" ]] || return 2
    while IFS= read -r value; do
      [[ "$value" == "$needle" ]] && return 0
    done < <(tr '\0' '\n' <"/proc/$pid/environ")
    return 1
  }
  _proc_start_ticks() {
    local pid="$1" stat
    [[ -r "/proc/$pid/stat" ]] || return 1
    stat=$(<"/proc/$pid/stat")
    stat=${stat#*) }
    printf '%s\n' "$stat" | awk '{print $20}'
  }
  _registry_append() {
    local pid="$1" pgid="$2" ppid="$3" user="$4" ticks="$5" identity="$6"
    local sequence="${run_dir}/registry.sequence" next intent entry commit lock="${run_dir}/registry.lock"
    local registry_tmp tries=0 current
    while ! mkdir "$lock" 2>/dev/null; do
      tries=$((tries + 1))
      (( tries < 100 )) || return 1
      sleep 0.01
    done
    current=$(_read "$sequence")
    [[ "$current" =~ ^[0-9]+$ ]] || {
      [[ -e "$sequence" ]] && { rmdir "$lock" 2>/dev/null || :; return 1; }
      current=0
    }
    next=$((current + 1))
    intent="${run_dir}/registry.${next}.intent"
    entry="${run_dir}/registry.${next}.entry"
    commit="${run_dir}/registry.${next}.commit"
    if ! printf 'run_id=%s sequence=%s state=intent pid=%s owner_epoch=%s\n' \
      "$run_id" "$next" "$pid" "$active_epoch" >"${intent}.tmp" ||
      ! chmod 600 "${intent}.tmp" || ! mv -f "${intent}.tmp" "$intent" ||
      ! sync -f "$intent" 2>/dev/null; then
      rm -f "${intent}.tmp"
      rmdir "$lock" 2>/dev/null || :
      return 1
    fi
    if ! printf 'run_id=%s sequence=%s pid=%s ppid=%s pgid=%s owner=%s start_ticks=%s identity=%s owner_epoch=%s\n' \
      "$run_id" "$next" "$pid" "$ppid" "$pgid" "$user" "$ticks" "$identity" "$active_epoch" >"${entry}.tmp" ||
      ! chmod 600 "${entry}.tmp" || ! mv -f "${entry}.tmp" "$entry" ||
      ! sync -f "$entry" 2>/dev/null; then
      rm -f "${entry}.tmp"
      rmdir "$lock" 2>/dev/null || :
      return 1
    fi
    if ! printf 'run_id=%s sequence=%s state=committed owner_epoch=%s\n' \
      "$run_id" "$next" "$active_epoch" >"${commit}.tmp" ||
      ! chmod 600 "${commit}.tmp" || ! mv -f "${commit}.tmp" "$commit" ||
      ! sync -f "$commit" 2>/dev/null; then
      rm -f "${commit}.tmp"
      rmdir "$lock" 2>/dev/null || :
      return 1
    fi
    if ! printf '%s\n' "$next" >"${sequence}.tmp.$BASHPID" ||
      ! chmod 600 "${sequence}.tmp.$BASHPID" ||
      ! mv -f "${sequence}.tmp.$BASHPID" "$sequence"; then
      rm -f "${sequence}.tmp.$BASHPID"
      rmdir "$lock" 2>/dev/null || :
      return 1
    fi
    registry_tmp="${run_dir}/descendant-registry.tmp.$BASHPID"
    [[ ! -L "${run_dir}/descendant-registry" ]] || {
      rmdir "$lock" 2>/dev/null || :
      return 1
    }
    [[ ! -e "${run_dir}/descendant-registry" ]] || cat "${run_dir}/descendant-registry" >"$registry_tmp" || {
      rm -f "$registry_tmp"
      rmdir "$lock" 2>/dev/null || :
      return 1
    }
    printf '%s\n' "$next" >>"$registry_tmp" &&
      chmod 600 "$registry_tmp" &&
      mv -f "$registry_tmp" "${run_dir}/descendant-registry" &&
      sync -f "${run_dir}/descendant-registry" 2>/dev/null
    local rc=$?
    rm -f "$registry_tmp"
    rmdir "$lock" 2>/dev/null || :
    return "$rc"
  }
  _registry_validate() {
    local sequence="$(_read "${run_dir}/registry.sequence")" expected=1 value
    [[ "$sequence" =~ ^[0-9]+$ && -f "${run_dir}/descendant-registry" &&
      ! -L "${run_dir}/descendant-registry" ]] || return 1
    while IFS= read -r value; do
      [[ "$value" == "$expected" ]] || return 1
      expected=$((expected + 1))
    done <"${run_dir}/descendant-registry"
    (( expected - 1 == sequence )) || return 1
    for ((value=1; value<=sequence; value++)); do
      [[ -f "${run_dir}/registry.${value}.intent" &&
        -f "${run_dir}/registry.${value}.entry" &&
        -f "${run_dir}/registry.${value}.commit" ]] || return 1
      grep -Eq "^run_id=${run_id//./\\.} sequence=${value} state=intent " \
        "${run_dir}/registry.${value}.intent" || return 1
      grep -Eq "^run_id=${run_id//./\\.} sequence=${value} state=committed " \
        "${run_dir}/registry.${value}.commit" || return 1
      grep -Eq "^run_id=${run_id//./\\.} sequence=${value} " \
        "${run_dir}/registry.${value}.entry" || return 1
    done
  }
  _registry_pids() {
    local sequence="$(_read "${run_dir}/registry.sequence")" value pid
    [[ "$sequence" =~ ^[0-9]+$ ]] || return 1
    for ((value=1; value<=sequence; value++)); do
      pid=$(sed -n 's/.* pid=\([0-9][0-9]*\) .*/\1/p' \
        "${run_dir}/registry.${value}.entry")
      [[ "$pid" =~ ^[0-9]+$ ]] || return 1
      printf '%s\n' "$pid"
    done
  }
  _boundary_prepare() {
    local boundary="${LIFECYCLE_CGROUP_ROOT}/nfv-e2e-${run_id}"
    [[ "${LIFECYCLE_LOCAL_REMOTE:-false}" == true ]] && return 0
    mkdir "$boundary" 2>/dev/null || return 1
    [[ -w "$boundary/cgroup.procs" && -w "$boundary/cgroup.kill" ]] || return 1
    _write "${run_dir}/cgroup_path" "$boundary" || return 1
  }
  _boundary_attach() {
    local pid="$1" boundary=$(_read "${run_dir}/cgroup_path")
    [[ "${LIFECYCLE_LOCAL_REMOTE:-false}" == true ]] && return 0
    [[ -n "$boundary" ]] || return 1
    printf '%s\n' "$pid" >"${boundary}/cgroup.procs"
  }
  _boundary_kill() {
    local boundary=$(_read "${run_dir}/cgroup_path")
    [[ -n "$boundary" && -w "$boundary/cgroup.kill" ]] || return 1
    printf '1\n' >"${boundary}/cgroup.kill"
  }
  _boundary_pids() {
    local boundary=$(_read "${run_dir}/cgroup_path")
    [[ -n "$boundary" && -r "$boundary/cgroup.procs" ]] || return 1
    cat "$boundary/cgroup.procs"
  }
  _proc_matches_ticks() {
    local pid="$1" ticks_file="$2" current_ticks
    [[ "$pid" =~ ^[0-9]+$ && "$(_read "$ticks_file")" =~ ^[0-9]+$ ]] || return 1
    current_ticks=$(_proc_start_ticks "$pid") || return 1
    [[ "$current_ticks" == "$(_read "$ticks_file")" ]]
  }
  _boundary_finalize() {
    local boundary=$(_read "${run_dir}/cgroup_path") members writers writer writer_pid writer_ticks
    [[ "${LIFECYCLE_LOCAL_REMOTE:-false}" == true || -z "$boundary" ]] && return 0
    [[ "$boundary" == "${LIFECYCLE_CGROUP_ROOT}/nfv-e2e-${run_id}" &&
      -d "$boundary" && ! -L "$boundary" ]] || return 1
    members=$(_boundary_pids) || return 1
    [[ -z "$members" ]] || return 1
    writers=$(_read "${run_dir}/record_writers")
    while read -r writer; do
      [[ -n "$writer" ]] || continue
      writer_pid=${writer%%:*}
      writer_ticks=${writer#*:}
      [[ "$writer_pid" =~ ^[0-9]+$ && "$writer_ticks" =~ ^[0-9]+$ ]] || return 1
      _proc_matches_ticks "$writer_pid" <(printf '%s\n' "$writer_ticks") && return 1
    done <<<"$writers"
    _write "${run_dir}/cgroup_removed" false || return 1
    rmdir "$boundary" 2>/dev/null || return 1
    _write "${run_dir}/cgroup_removed" true
  }
  _proc_pgid() {
    local pid="$1"
    ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' '
  }
  _track_descendants() {
    local root_pid="$1" tracked_file="${run_dir}/tracked_pids" tracked_groups_file="${run_dir}/tracked_pgids"
    local frontier_file="${run_dir}/tracked_frontier" known frontier next all_pids pid pgid ppid user ticks new_frontier=
    if [[ -f "$frontier_file" ]]; then
      frontier=$(_read "$frontier_file")
    else
      frontier="$root_pid"
      _write "$frontier_file" "$root_pid" || return 1
    fi
    known=$(_read "$tracked_file" | tr '\n' ' ')
    if [[ -z "$known" ]]; then
      printf '%s\n' "$root_pid" >"$tracked_file" || return 1
      ticks=$(_proc_start_ticks "$root_pid") || {
        _write "${run_dir}/cleanup-enumeration-failed" initial_start_ticks
        return 1
      }
      user=$(ps -o user= -p "$root_pid" 2>/dev/null | tr -d ' ') || {
        _write "${run_dir}/cleanup-enumeration-failed" initial_owner
        return 1
      }
      _proc_identity "$root_pid" || {
        _write "${run_dir}/cleanup-enumeration-failed" initial_run_identity
        return 1
      }
      _registry_append "$root_pid" "$(_proc_pgid "$root_pid")" "$(_read "${run_dir}/supervisor_pid")" \
        "$user" "$ticks" "$run_id" || {
        _write "${run_dir}/cleanup-enumeration-failed" initial_registry
        return 1
      }
      known="$root_pid"
    fi
    [[ -n "$frontier" ]] || frontier="$root_pid"
    if [[ ! -f "$tracked_groups_file" ]]; then
      pgid=$(_proc_pgid "$root_pid" 2>/dev/null || :)
      if [[ "$pgid" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$pgid" >"$tracked_groups_file" || return 1
      else
        : >"$tracked_groups_file" || return 1
        _write "${run_dir}/tracking_root_exited" true || return 1
      fi
    fi
    if ! next=$(ps -eo pid=,ppid= 2>/dev/null); then
      _write "${run_dir}/cleanup-enumeration-failed" descendants || return 1
      return 1
    fi
    next=$(printf '%s\n' "$next" | awk -v roots="$frontier" '
      BEGIN { count=split(roots, root); for (i=1; i<=count; i++) wanted[root[i]]=1 }
      $2 in wanted { print $1 }')
    if ! all_pids=$(ps -eo pid= 2>/dev/null); then
      _write "${run_dir}/cleanup-enumeration-failed" process_identity_scan || return 1
      return 1
    fi
    while read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      case " $known " in
        *" $pid "*) ;;
        *) _proc_identity "$pid" && next+=$'\n'"$pid" ;;
      esac
    done <<<"$all_pids"
    while read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      case " $known " in
        *" $pid "*) ;;
        *)
          pgid=$(_proc_pgid "$pid") || return 1
          [[ "$pgid" =~ ^[0-9]+$ ]] || return 1
          ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
          user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
          ticks=$(_proc_start_ticks "$pid") || return 1
          _proc_identity "$pid" || return 1
          state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
          comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
          _write_evidence "${run_dir}/descendant_evidence" "$pid" "$pgid" "$user" "$state" "$comm" identity || return 1
          printf '%s\n' "$pid" >>"$tracked_file" || return 1
          _registry_append "$pid" "$pgid" "$ppid" "$user" "$ticks" "$run_id" || return 1
          case " $(_read "$tracked_groups_file" | tr '\n' ' ') " in
            *" $pgid "*) ;;
            *) printf '%s\n' "$pgid" >>"$tracked_groups_file" || return 1 ;;
          esac
          known+=" $pid"
          new_frontier+=" $pid"
          ;;
      esac
    done <<<"$next"
    _write "$frontier_file" "$new_frontier" || return 1
  }
  _members() {
    local pid pgid ppid user state comm identity tracked_pids tracked_pgids workload_start_ticks supervisor_ticks boundary
    local process_list current_ticks tracked group_tracked
    boundary=$(_read "${run_dir}/cgroup_path")
    workload_start_ticks=$(_read "${run_dir}/workload_start_ticks")
    tracked_pids=$(_read "${run_dir}/tracked_pids" | tr '\n' ' ')
    tracked_pgids=$(_read "${run_dir}/tracked_pgids" | tr '\n' ' ')
    if [[ -n "$boundary" ]]; then
      process_list=$(_boundary_pids) || {
        _write "${run_dir}/cleanup-enumeration-failed" boundary || :
        printf 'AMBIGUOUS REASON=boundary_enumeration_failure\n'
        return 0
      }
    elif ! process_list=$(ps -eo pid=,pgid=,user=,stat=,comm= 2>/dev/null); then
      _write "${run_dir}/cleanup-enumeration-failed" members || :
      printf 'AMBIGUOUS REASON=process_enumeration_failure\n'
      return 0
    else
      process_list=$(printf '%s\n' "$process_list" | awk -v pids="$tracked_pids" -v groups="$tracked_pgids" '
        BEGIN {
          n=split(pids, p); for (i=1; i<=n; i++) wanted[p[i]]=1
          n=split(groups, g); for (i=1; i<=n; i++) group[g[i]]=1
        }
        ($1 in wanted || $2 in group) { print }')
    fi
    while read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      case $'\n'"$process_list"$'\n' in
        *$'\n'"$pid"$'\n'*) ;;
        *) process_list+=$'\n'"$pid" ;;
      esac
    done <<<"$tracked_pids"
    while read -r pid _; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      read -r pgid user state comm < <(ps -o pgid=,user=,stat=,comm= -p "$pid" 2>/dev/null) || {
        [[ -e "/proc/$pid" ]] || continue
        printf 'AMBIGUOUS PID=%s REASON=process_metadata_failure\n' "$pid"
        continue
      }
      state=${state//[[:space:]]/}; comm=${comm//[^A-Za-z0-9_.:-]/_}
      [[ "$pid" == "$supervisor_pid" &&
        "$(_proc_start_ticks "$pid")" == "$supervisor_ticks" &&
        "$supervisor_ticks" =~ ^[0-9]+$ ]] && continue
      if [[ "$pid" == "$preserve_pid" &&
        "$(_proc_start_ticks "$pid")" == "$workload_start_ticks" &&
        "$workload_start_ticks" =~ ^[0-9]+$ ]]; then
        continue
      fi
      tracked=false; group_tracked=false
      case " $tracked_pids " in *" $pid "*) tracked=true;; esac
      case " $tracked_pgids " in *" $pgid "*) group_tracked=true;; esac
      if [[ -z "$boundary" && "$pgid" != "$workload_pgid" &&
        "$tracked" != true && "$group_tracked" != true ]]; then
        _proc_identity "$pid" || {
          printf 'AMBIGUOUS PID=%s PGID=%s OWNER=%s STATE=%s COMM=%s REASON=missing_run_identity\n' \
            "$pid" "$pgid" "$user" "$state" "$comm"
          continue
        }
      elif ! _proc_identity "$pid"; then
        printf 'AMBIGUOUS PID=%s PGID=%s OWNER=%s STATE=%s COMM=%s REASON=missing_run_identity\n' \
          "$pid" "$pgid" "$user" "$state" "$comm"
        continue
      fi
      current_ticks=$(_proc_start_ticks "$pid") || {
        printf 'AMBIGUOUS PID=%s PGID=%s OWNER=%s STATE=%s COMM=%s REASON=missing_start_ticks\n' \
          "$pid" "$pgid" "$user" "$state" "$comm"
        continue
      }
      if [[ "$user" != "$owner" && "$user" != "$workload_user" ]]; then
        printf 'AMBIGUOUS PID=%s PGID=%s OWNER=%s STATE=%s COMM=%s REASON=owner_mismatch\n' \
          "$pid" "$pgid" "$user" "$state" "$comm"
        continue
      fi
      if [[ "$user" == "$owner" ]]; then
        identity=controller-owned
      else
        identity=workload-owned
      fi
      if [[ "$tracked" != true ]]; then
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || {
          printf 'AMBIGUOUS PID=%s PGID=%s OWNER=%s STATE=%s COMM=%s REASON=missing_parent\n' \
            "$pid" "$pgid" "$user" "$state" "$comm"
          continue
        }
        [[ "$ppid" =~ ^[0-9]+$ ]] || {
          printf 'AMBIGUOUS PID=%s PGID=%s OWNER=%s STATE=%s COMM=%s REASON=invalid_parent\n' \
            "$pid" "$pgid" "$user" "$state" "$comm"
          continue
        }
        identity=escaped-owned
        _write_evidence "${run_dir}/descendant_evidence" "$pid" "$pgid" "$user" "$state" "$comm" "$identity" || {
          printf 'AMBIGUOUS PID=%s PGID=%s OWNER=%s STATE=%s COMM=%s REASON=evidence_write_failure\n' \
            "$pid" "$pgid" "$user" "$state" "$comm"
          continue
        }
        _registry_append "$pid" "$pgid" "$ppid" "$user" "$current_ticks" "$run_id" || {
          printf 'AMBIGUOUS PID=%s PGID=%s OWNER=%s STATE=%s COMM=%s REASON=registry_write_failure\n' \
            "$pid" "$pgid" "$user" "$state" "$comm"
          continue
        }
        printf '%s\n' "$pid" >>"$tracked_file" || {
          printf 'AMBIGUOUS PID=%s PGID=%s OWNER=%s STATE=%s COMM=%s REASON=tracking_write_failure\n' \
            "$pid" "$pgid" "$user" "$state" "$comm"
          continue
        }
        case " $tracked_pgids " in
          *" $pgid "*) ;;
          *) printf '%s\n' "$pgid" >>"$tracked_groups_file" || {
            printf 'AMBIGUOUS PID=%s PGID=%s OWNER=%s STATE=%s COMM=%s REASON=group_tracking_write_failure\n' \
              "$pid" "$pgid" "$user" "$state" "$comm"
            continue
          };;
        esac
      fi
      _write "${run_dir}/observed_ticks_${pid}" "$current_ticks" || {
        printf 'AMBIGUOUS PID=%s PGID=%s OWNER=%s STATE=%s COMM=%s REASON=observation_write_failure\n' \
          "$pid" "$pgid" "$user" "$state" "$comm"
        continue
      }
      printf '%s %s %s %s %s %s %s\n' "$pid" "$pgid" "$user" "$state" "$comm" "$identity" "$current_ticks"
    done <<<"$process_list"
  }
  _cleanup() {
    local workload_pgid="$1" supervisor_pid="$2" cause="$3" preserve_pid="${4:-}"
    local workload_pid="${5:-$(_read "${run_dir}/workload_pid")}" deadline="${6:-$(( $(_now) + ${LIFECYCLE_CLEANUP_GRACE_SECONDS:-600} ))}"
    local evidence="${run_dir}/cleanup-evidence.tmp.$BASHPID" survivors members member pid pgid user state comm identity ticks remaining ambiguous=false registry_valid=true
    local boundary=$(_read "${run_dir}/cgroup_path")
    if ! _registry_validate; then
      printf 'AMBIGUOUS REASON=registry_tail_invalid\n' >"$evidence" || return 1
      ambiguous=true
      registry_valid=false
    fi
    if [[ "$registry_valid" == true ]]; then
      while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        case " $(_read "${run_dir}/tracked_pids" | tr '\n' ' ') " in
          *" $pid "*) ;;
          *) printf '%s\n' "$pid" >>"${run_dir}/tracked_pids" || {
            ambiguous=true
            break
          };;
        esac
      done < <(_registry_pids)
    fi
    members=$(_members "$workload_pgid" "$supervisor_pid" "$preserve_pid" "$workload_pid")
    [[ -z "$members" ]] && {
      sleep 1
      members=$(_members "$workload_pgid" "$supervisor_pid" "$preserve_pid" "$workload_pid")
    }
    if [[ -f "${run_dir}/cleanup-enumeration-failed" ]]; then
      printf 'AMBIGUOUS REASON=cleanup_enumeration_failed detail=%s\n' \
        "$(_read "${run_dir}/cleanup-enumeration-failed")" >>"$evidence" || return 1
      ambiguous=true
    fi
    if [[ -f "${run_dir}/tracking_root_exited" ]]; then
      printf 'AMBIGUOUS REASON=root_exited_before_tracking\n' >>"$evidence" || return 1
      ambiguous=true
    fi
    if [[ -f "${run_dir}/supervisor-recovery-ambiguous" ]]; then
      cat "${run_dir}/supervisor-recovery-ambiguous" >>"$evidence" || return 1
      ambiguous=true
    fi
    if [[ -n "$boundary" && -n "$members" ]]; then
      if _boundary_kill; then
        printf 'KERNEL_BOUNDARY_SIGNAL=KILL\n' >>"$evidence" || return 1
      else
        printf 'AMBIGUOUS REASON=kernel_boundary_signal_failed\n' >>"$evidence" || return 1
        ambiguous=true
      fi
    else
      while read -r member; do
        read -r pid pgid user state comm identity ticks <<<"$member"
        [[ -n "$pid" ]] || continue
        if [[ "$pid" == AMBIGUOUS ]]; then
          printf '%s\n' "$member" >>"$evidence" || return 1
          ambiguous=true
          continue
        fi
        _write_evidence "$evidence" "$pid" "$pgid" "$user" "$state" "$comm" "$identity" || return 1
        if ! _signal_owned_process "$pid" TERM "${run_dir}/observed_ticks_${pid}"; then
          printf 'AMBIGUOUS PID=%s PGID=%s OWNER=%s STATE=%s COMM=%s REASON=identity_changed\n' \
            "$pid" "$pgid" "$user" "$state" "$comm" >>"$evidence" || return 1
          ambiguous=true
        fi
      done <<<"$members"
    fi
    while (( $(_now) < deadline )); do
      _write "${run_dir}/supervisor_progress" "$(_now)" || return 1
      survivors=$(_members "$workload_pgid" "$supervisor_pid" "$preserve_pid" "$workload_pid")
      [[ -z "$survivors" ]] && break
      sleep 1
    done
    if [[ -n "${survivors:-}" ]]; then
      if [[ -n "$boundary" ]]; then
        _boundary_kill || ambiguous=true
      else
        while read -r pid pgid user state comm identity ticks; do
          [[ "$pid" =~ ^[0-9]+$ ]] || continue
          _signal_owned_process "$pid" KILL "${run_dir}/observed_ticks_${pid}" || ambiguous=true
        done <<<"$survivors"
      fi
      remaining=$(( deadline - $(_now) ))
      if (( remaining > 0 )); then
        sleep "$(( remaining > 1 ? 1 : remaining ))"
      fi
      survivors=$(_members "$workload_pgid" "$supervisor_pid" "$preserve_pid" "$workload_pid")
    fi
    if [[ "$ambiguous" == true || -n "${survivors:-}" ]]; then
      if [[ "$ambiguous" == true ]]; then
        _write "${run_dir}/cleanup_cause" ambiguous_ownership || return 1
      else
        _write "${run_dir}/cleanup_cause" survivors_after_kill || return 1
      fi
      _write "${run_dir}/cleanup_status" failed || return 1
      _write "${run_dir}/cleanup_evidence" "$(cat "$evidence"; printf '%s\n' "$survivors")" || return 1
      return 1
    fi
    if [[ -n "$boundary" ]] && ! _boundary_finalize; then
      printf 'AMBIGUOUS REASON=cgroup_remove_failed PATH=%s\n' "$boundary" >>"$evidence" || return 1
      _write "${run_dir}/cleanup_cause" cgroup_remove_failed || return 1
      _write "${run_dir}/cleanup_status" failed || return 1
      _write "${run_dir}/cleanup_evidence" "$(cat "$evidence")" || return 1
      return 1
    fi
    _write "${run_dir}/cleanup_cause" "$cause" || return 1
    _write "${run_dir}/cleanup_evidence" "$(cat "$evidence")" || return 1
    return 0
  }
  _publish_terminal() {
    local terminal_state="$1" terminal_file="${run_dir}/terminal.snapshot" sequence tag tmp
    [[ "$terminal_state" == terminal || "$terminal_state" == cleanup_failed ]] || return 64
    [[ ! -e "$terminal_file" ]] || return 0
    sequence=$(_read "${run_dir}/record.sequence")
    [[ "$sequence" =~ ^[0-9]+$ ]] || return 1
    tag=$(_record_tag "$terminal_state" "$(_read "${run_dir}/workload_status")" \
      "$(_read "${run_dir}/workload_exit")" "$(_read "${run_dir}/terminal_cause")" \
      "$(_read "${run_dir}/cleanup_status")" "$sequence") || return 1
    tmp="${terminal_file}.tmp.$BASHPID"
    {
      printf 'run_id=%s\nkind=%s\nbuild_id=%s\nstate=%s\nworkload_status=%s\nworkload_exit=%s\n' \
        "$run_id" "$(_read "${run_dir}/kind")" "$(_read "${run_dir}/build_id")" \
        "$terminal_state" "$(_read "${run_dir}/workload_status")" "$(_read "${run_dir}/workload_exit")"
      printf 'terminal_cause=%s\ncleanup_status=%s\ncleanup_cause=%s\nrecord_sequence=%s\nowner_epoch=%s\nrecord_auth=%s\n' \
        "$(_read "${run_dir}/terminal_cause")" "$(_read "${run_dir}/cleanup_status")" \
        "$(_read "${run_dir}/cleanup_cause")" "$sequence" "$active_epoch" "$tag"
      printf 'cleanup_evidence=%s\n' "$(_read "${run_dir}/cleanup_evidence" | base64 | tr -d '\n')"
    } >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp" && sync -f "$tmp" 2>/dev/null || :
    mv -f "$tmp" "$terminal_file" || { rm -f "$tmp"; return 1; }
    _write "${run_dir}/terminal_published" true
  }
  _snapshot_value() {
    local key="$1" snapshot="${run_dir}/terminal.snapshot" value
    [[ -f "$snapshot" && ! -L "$snapshot" ]] || return 1
    value=$(sed -n "s/^${key}=//p" "$snapshot")
    if [[ "$key" == cleanup_evidence ]]; then
      [[ -n "$value" ]] && printf '%s' "$value" | base64 -d || :
    else
      printf '%s\n' "$value"
    fi
  }
  _child_exited() {
    local pid="$1" state
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || :)
    [[ "$state" == Z* ]]
  }
  _signal_owned_process() {
    local pid="$1" signal="$2" ticks_file="$3"
    if [[ "${LIFECYCLE_LOCAL_REMOTE:-false}" != true ]]; then
      printf 'kernel-bound signal target required\n' >&2
      return 2
    fi
    [[ "$pid" =~ ^[0-9]+$ ]] || return 2
    if ! _proc_matches_ticks "$pid" "$ticks_file"; then
      [[ -e "/proc/$pid" ]] && return 2
      return 0
    fi
    if ! _proc_identity "$pid"; then
      [[ -e "/proc/$pid" ]] && return 2
      return 0
    fi
    kill "-$signal" "$pid" 2>/dev/null || :
  }
  _supervisor() {
    local run_dir="$1" run_id="$2" kind="$3" owner="$4" command_file="$5" workspace="$6" supervisor_pid=$BASHPID
    local wp='' wpgid='' rc=0 cleanup_rc=0 cause='' lease now cancel cleanup_deadline workload_dir
    [[ -n "$workspace" && "$workspace" == /* ]] || return 64
    [[ "${LIFECYCLE_LOCAL_REMOTE:-false}" == true || -d "$workspace" ]] || return 65
    workload_dir="${workspace}/.nfv-e2e-workload/${run_id}"
    mkdir -p -m 733 "$workload_dir" || return 65
    _boundary_prepare || {
      _write "${run_dir}/cleanup_status" failed || :
      _write "${run_dir}/cleanup_cause" missing_kernel_boundary || :
      _write "${run_dir}/state" cleanup_failed || :
      return 66
    }
    export NFV_E2E_RUN_ID="$run_id" NFV_E2E_WORKSPACE="$workspace" \
      NFV_E2E_WORKLOAD_KIND="$kind" NFV_E2E_WORKLOAD_DIR="$workload_dir"
    _write "${run_dir}/supervisor_progress" "$(_now)"
    _write "${run_dir}/supervisor_pid" "$supervisor_pid"
    _write "${run_dir}/supervisor_identity" "$supervisor_pid:$run_id"
    _write "${run_dir}/supervisor_start_ticks" "$(_proc_start_ticks "$supervisor_pid")"
    _write "${run_dir}/state" running
    (
      cd "$workspace" || exit 126
      if [[ "${LIFECYCLE_LOCAL_REMOTE:-false}" == true ]]; then
        exec env NFV_E2E_RUN_ID="$run_id" NFV_E2E_RUN_DIR="$workload_dir" \
          NFV_E2E_WORKSPACE="$workspace" NFV_E2E_WORKLOAD_KIND="$kind" \
          NFV_E2E_WORKLOAD_DIR="$workload_dir" setsid --wait bash "$command_file"
      else
        exec env NFV_E2E_RUN_ID="$run_id" NFV_E2E_RUN_DIR="$workload_dir" \
          NFV_E2E_WORKSPACE="$workspace" NFV_E2E_WORKLOAD_KIND="$kind" \
          NFV_E2E_WORKLOAD_DIR="$workload_dir" \
          sudo -n -u "$workload_user" env NFV_E2E_RUN_ID="$run_id" \
          NFV_E2E_RUN_DIR="$workload_dir" NFV_E2E_WORKSPACE="$workspace" \
          NFV_E2E_WORKLOAD_KIND="$kind" NFV_E2E_WORKLOAD_DIR="$workload_dir" \
          setsid --wait bash "$command_file"
      fi
    ) >"${run_dir}/workload.log" 2>&1 &
    wp=$!
    for _ in {1..50}; do
      wpgid=$(_proc_pgid "$wp" 2>/dev/null || :)
      [[ "$wpgid" =~ ^[0-9]+$ ]] && break
      sleep 0.01
    done
    [[ "$wpgid" =~ ^[0-9]+$ ]] || wpgid=$(_proc_pgid "$wp") || :
    _write "${run_dir}/workload_pid" "$wp"
    _write "${run_dir}/workload_pgid" "$wpgid"
    _write "${run_dir}/workload_start_ticks" "$(_proc_start_ticks "$wp")"
    _boundary_attach "$wp" || _write "${run_dir}/cleanup-enumeration-failed" boundary_attach || :
    sleep 0.1
    if ! _track_descendants "$wp"; then
      _write "${run_dir}/cleanup-enumeration-failed" initial_tracking || :
    fi
    _write "${run_dir}/workload_status" running
    _write "${run_dir}/supervisor_ready" true
    while :; do
      now=$(_now); lease=$(_read "${run_dir}/lease"); cancel=$(_read "${run_dir}/cancel_requested")
      _write "${run_dir}/supervisor_progress" "$now"
      if ! _track_descendants "$wp"; then
        _write "${run_dir}/cleanup-enumeration-failed" descendant_tracking || :
      fi
      if _child_exited "$wp"; then
        wait "$wp" || rc=$?
        _write "${run_dir}/workload_status" exited
        _write "${run_dir}/workload_exit" "$rc"
        if (( rc == 0 )); then cause=completion; else cause=failure; fi
        break
      fi
      if [[ -n "$cancel" ]]; then
        cause=cancel
        _signal_owned_process "$wp" TERM "${run_dir}/workload_start_ticks" || :
        break
      fi
      if [[ "$lease" =~ ^[0-9]+$ ]] && (( now >= lease )); then
        cause=lease_expired
        _signal_owned_process "$wp" TERM "${run_dir}/workload_start_ticks" || :
        break
      fi
      sleep 1
    done
    _write "${run_dir}/terminal_cause" "$cause"
    _write "${run_dir}/state" cleanup
    _write "${run_dir}/cleanup_status" cleaning
    cleanup_deadline=$(( $(_now) + ${LIFECYCLE_CLEANUP_GRACE_SECONDS:-600} ))
    _write "${run_dir}/cleanup_deadline" "$cleanup_deadline" || cleanup_rc=1
    _cleanup "$wpgid" "$supervisor_pid" "$cause" "$([[ "$cause" == completion ]] && printf '%s' "$wp")" "$wp" "$cleanup_deadline" ||
      cleanup_rc=$?
    if (( cleanup_rc == 0 )); then
      _write "${run_dir}/cleanup_status" verified || cleanup_rc=$?
    else
      _write "${run_dir}/cleanup_status" failed || :
    fi
    if [[ ! -f "${run_dir}/workload_exit" ]]; then
      while ! _child_exited "$wp" && (( $(_now) < cleanup_deadline )); do
        sleep 1
      done
      if _child_exited "$wp"; then
        wait "$wp" || rc=$?
        _write "${run_dir}/workload_status" exited
        _write "${run_dir}/workload_exit" "$rc"
      else
        _write "${run_dir}/workload_status" cleanup_failed
      fi
    fi
    if [[ "$(_read "${run_dir}/cleanup_status")" == verified ]]; then
      _write "${run_dir}/state" terminal
    else
      _write "${run_dir}/state" cleanup_failed
    fi
    _write "${run_dir}/supervisor_done" true
    _publish_terminal "$(_read "${run_dir}/state")" || {
      _write "${run_dir}/state" cleanup_failed || :
      _publish_terminal cleanup_failed || :
    }
  }
  _recover_dead_supervisor() {
    local current_state="$(_read "${run_dir}/state")" supervisor_pid="$(_read "${run_dir}/supervisor_pid")"
    local recovery_pid workload_pid workload_pgid launcher_pid progress now cancel_requested starting_deadline existing_cause
    local supervisor_unresponsive=false lock_dir="${run_dir}/recovery.lock"
    [[ "$current_state" == starting || "$current_state" == running || "$current_state" == cleanup ||
      "$current_state" == recovering ]] || return 0
    now=$(_now)
    if [[ "$current_state" == starting ]]; then
      launcher_pid=$(_read "${run_dir}/launcher_pid")
      starting_deadline=$(_read "${run_dir}/starting_deadline")
      if [[ "$starting_deadline" =~ ^[0-9]+$ && "$now" -lt "$starting_deadline" ]]; then
        _proc_matches_ticks "$launcher_pid" "${run_dir}/launcher_start_ticks" || return 0
        return 0
      fi
      supervisor_unresponsive=true
      [[ "$supervisor_pid" =~ ^[0-9]+$ ]] || supervisor_pid="$launcher_pid"
    fi
    if [[ "$current_state" == running && "$(_read "${run_dir}/supervisor_ready")" != true ]]; then
      progress=$(_read "${run_dir}/supervisor_progress")
      if _proc_matches_ticks "$supervisor_pid" "${run_dir}/supervisor_start_ticks" &&
        [[ "$progress" =~ ^[0-9]+$ ]] && (( now - progress <= LIFECYCLE_SUPERVISOR_PROGRESS_TIMEOUT_SECONDS )); then
        return 0
      fi
      supervisor_unresponsive=true
    elif [[ "$current_state" == recovering ]]; then
      recovery_pid=$(_read "${run_dir}/recovery_pid")
      if [[ "$recovery_pid" =~ ^[0-9]+$ ]] &&
        _proc_matches_ticks "$recovery_pid" "${run_dir}/recovery_start_ticks"; then
        return 0
      fi
      [[ -f "${run_dir}/recovery_done" ]] && return 0
      _write "${run_dir}/terminal_cause" dead_supervisor || :
      _write "${run_dir}/cleanup_status" failed || :
      _write "${run_dir}/cleanup_cause" recovery_claim_lost || :
      _write "${run_dir}/cleanup_evidence" 'AMBIGUOUS REASON=recovery_claim_lost' || :
      _write "${run_dir}/state" cleanup_failed || :
      rmdir "$lock_dir" 2>/dev/null || :
      return 0
    else
      progress=$(_read "${run_dir}/supervisor_progress")
      cancel_requested=$(_read "${run_dir}/cancel_requested")
      if _proc_matches_ticks "$supervisor_pid" "${run_dir}/supervisor_start_ticks" &&
        [[ "$progress" =~ ^[0-9]+$ ]] &&
        (( now - progress <= LIFECYCLE_SUPERVISOR_PROGRESS_TIMEOUT_SECONDS )); then
        return 0
      fi
      supervisor_unresponsive=true
    fi
    workload_pid=$(_read "${run_dir}/workload_pid")
    workload_pgid=$(_read "${run_dir}/workload_pgid")
    if [[ ! "$workload_pid" =~ ^[0-9]+$ || ! "$workload_pgid" =~ ^[0-9]+$ ]]; then
      _write "${run_dir}/terminal_cause" dead_supervisor
      _write "${run_dir}/cleanup_status" failed
      _write "${run_dir}/cleanup_cause" missing_workload_identity
      _write "${run_dir}/cleanup_evidence" 'AMBIGUOUS REASON=missing_workload_identity'
      _write "${run_dir}/state" cleanup_failed
      return 0
    fi
    if ! mkdir "$lock_dir" 2>/dev/null; then
      recovery_pid=$(_read "${run_dir}/recovery_pid")
      if [[ "$recovery_pid" =~ ^[0-9]+$ ]] &&
        _proc_matches_ticks "$recovery_pid" "${run_dir}/recovery_start_ticks" &&
        _proc_identity "$recovery_pid"; then
        return 0
      fi
      if [[ -f "${run_dir}/recovery_pid" ]] && rmdir "$lock_dir" 2>/dev/null; then
        _write "${run_dir}/state" running || return 0
        supervisor_unresponsive=true
      fi
      return 0
    fi
    _write "${run_dir}/state" recovering || { rmdir "$lock_dir" 2>/dev/null || :; return 0; }
    _advance_epoch || {
      _write "${run_dir}/cleanup_cause" recovery_claim_lost || :
      _write "${run_dir}/cleanup_status" failed || :
      _write "${run_dir}/cleanup_evidence" 'AMBIGUOUS REASON=recovery_claim_lost' || :
      _write "${run_dir}/state" cleanup_failed || :
      rmdir "$lock_dir" 2>/dev/null || :
      return 0
    }
    rm -f "${run_dir}/recovery_done" "${run_dir}/recovery_pid" \
      "${run_dir}/recovery_start_ticks" "${run_dir}/recovery_identity"
    existing_cause=$(_read "${run_dir}/terminal_cause")
    [[ -n "$existing_cause" ]] || _write "${run_dir}/terminal_cause" dead_supervisor
    (
      local workload_pid workload_pgid cleanup_deadline cleanup_rc=0 rc existing_exit cause workload_status=unknown
      local supervisor_signal_failed=false
      if [[ "$supervisor_unresponsive" == true && "$supervisor_pid" =~ ^[0-9]+$ ]]; then
        if ! _signal_owned_process "$supervisor_pid" TERM "${run_dir}/supervisor_start_ticks"; then
          _write "${run_dir}/supervisor-recovery-ambiguous" \
            "AMBIGUOUS PID=${supervisor_pid} REASON=supervisor_identity_changed"
          supervisor_signal_failed=true
        fi
        sleep 1
        if ! _signal_owned_process "$supervisor_pid" KILL "${run_dir}/supervisor_start_ticks"; then
          _write "${run_dir}/supervisor-recovery-ambiguous" \
            "AMBIGUOUS PID=${supervisor_pid} REASON=supervisor_identity_changed"
          supervisor_signal_failed=true
        fi
      fi
      workload_pid=$(_read "${run_dir}/workload_pid")
      workload_pgid=$(_read "${run_dir}/workload_pgid")
      cause=$(_read "${run_dir}/terminal_cause")
      cleanup_deadline=$(_read "${run_dir}/cleanup_deadline")
      if ! [[ "$cleanup_deadline" =~ ^[0-9]+$ ]]; then
        cleanup_deadline=$(( $(_now) + ${LIFECYCLE_CLEANUP_GRACE_SECONDS:-600} ))
        _write "${run_dir}/cleanup_deadline" "$cleanup_deadline" || cleanup_rc=1
      fi
      [[ "$supervisor_signal_failed" == true ]] && cleanup_rc=1
      _cleanup "$workload_pgid" "$supervisor_pid" "${cause:-dead_supervisor}" '' "$workload_pid" "$cleanup_deadline" ||
        cleanup_rc=$?
      existing_exit=$(_read "${run_dir}/workload_exit")
      if [[ "$existing_exit" =~ ^[0-9]+$ ]]; then
        workload_status=exited
      elif _child_exited "$workload_pid"; then
        workload_status=unknown
      fi
      _write "${run_dir}/workload_status" "$workload_status"
      if (( cleanup_rc == 0 )) && [[ "$(_read "${run_dir}/cleanup_status")" == verified &&
        "$workload_status" == exited ]]; then
        _write "${run_dir}/state" terminal
      else
        _write "${run_dir}/state" cleanup_failed
      fi
      _write "${run_dir}/supervisor_done" true
      _write "${run_dir}/recovery_done" true
      _publish_terminal "$(_read "${run_dir}/state")" || {
        _write "${run_dir}/state" cleanup_failed || :
        _publish_terminal cleanup_failed || :
      }
    ) >"${run_dir}/recovery.log" 2>&1 &
    recovery_pid=$!
    if ! {
      _write "${run_dir}/recovery_pid" "$recovery_pid" &&
        _write "${run_dir}/recovery_start_ticks" "$(_proc_start_ticks "$recovery_pid")" &&
        _write "${run_dir}/recovery_identity" "$recovery_pid:$run_id"
    }; then
      kill "$recovery_pid" 2>/dev/null || :
      _write "${run_dir}/cleanup_cause" recovery_claim_lost || :
      _write "${run_dir}/cleanup_status" failed || :
      _write "${run_dir}/cleanup_evidence" 'AMBIGUOUS REASON=recovery_claim_lost' || :
      _write "${run_dir}/state" cleanup_failed || :
      rmdir "$lock_dir" 2>/dev/null || :
      return 0
    fi
  }
  _workspace_validate() {
    local workspace="$1" expected_makefile lab_env
    [[ "$workspace" == /* && -d "$workspace" && ! -L "$workspace" ]] || return 68
    expected_makefile="${LIFECYCLE_EXPECTED_MAKEFILE:-Makefile}"
    [[ "$expected_makefile" != /* && "$expected_makefile" != *'..'* &&
      "$expected_makefile" =~ ^[A-Za-z0-9._/-]+$ ]] || return 68
    [[ -f "$workspace/$expected_makefile" && ! -L "$workspace/$expected_makefile" ]] || return 68
    lab_env="${LIFECYCLE_LAB_ENV:-$workspace/lab-init.env}"
    [[ "$lab_env" == /* && "$lab_env" != *'..'* &&
      -f "$lab_env" && ! -L "$lab_env" ]] || return 68
    [[ "$lab_env" != "$workspace/$expected_makefile" ]] || return 68
  }
  case "$op" in
    reserve)
      run_dir="$1"; run_id="$2"; kind="$3"; build_id="$4"; lease="$5"; workspace="${6:-}"
      _safe_path "$run_dir" || return 64
      _lifecycle_valid_id "$run_id" && _lifecycle_valid_kind "$kind" ||
        return 64
      command -v setsid >/dev/null 2>&1 || { printf '%s\n' 'setsid unavailable' >&2; return 69; }
      if [[ "${LIFECYCLE_LOCAL_REMOTE:-false}" != true ]]; then
        [[ -n "$workspace" ]] || return 68
        _workspace_validate "$workspace" || return 68
      fi
      _safe_path "$workspace" || return 64
      mkdir -p "${run_dir%/*}" && mkdir -m 700 "$run_dir" 2>/dev/null || return 73
      chmod 700 "$run_dir" || return 73
      _write "$run_dir/workspace" "$workspace" || return 74
      owner=$(id -un)
      local capability
      capability=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n') || return 74
      if ! {
        _write "$run_dir/run_id" "$run_id" &&
          _write "$run_dir/kind" "$kind" &&
          _write "$run_dir/build_id" "$build_id" &&
          _write "$run_dir/owner" "$owner" &&
          _write "$run_dir/controller_user" "$owner" &&
          _write "$run_dir/workload_user" "$workload_user" &&
          _write "$run_dir/created_at" "$(_now)" &&
          _write "$run_dir/lease" "$lease" &&
          _write "$run_dir/auth_capability" "$capability" &&
          _write "$run_dir/owner_epoch" 1 &&
          printf '%s\n' 0 >"$run_dir/record.sequence" &&
          chmod 600 "$run_dir/record.sequence" &&
          printf '%s\n' 0 >"$run_dir/registry.sequence" &&
          chmod 600 "$run_dir/registry.sequence" &&
          : >"$run_dir/descendant-registry" &&
          chmod 600 "$run_dir/descendant-registry"
      }; then
        return 74
      fi
      active_epoch=1
      active_sequence=0
      record_auth_enabled=true
      if ! {
        _write "$run_dir/state" reserved &&
          _write "$run_dir/workload_status" not_started &&
          _write "$run_dir/cleanup_status" not_started
      }; then
        return 74
      fi
      printf 'reserved verifier=%s epoch=%s\n' "$capability" "$active_epoch"
      ;;
    start)
      run_dir="$1"; run_id="$2"; kind="$3"; command_payload="$4"; capability="$5"; cleanup_grace="${6:-600}"; workspace="${7:-}"
      _verify_run "$run_dir" "$run_id" "$capability" 1 || return $?
      [[ -n "$workspace" ]] || workspace=$(_read "$run_dir/workspace")
      _safe_path "$workspace" || return 64
      [[ "$(_read "$run_dir/kind")" == "$kind" && "$(_read "$run_dir/state")" == reserved ]] || return 65
      [[ "$cleanup_grace" =~ ^[1-9][0-9]*$ ]] || return 64
      command_file="$run_dir/workload.sh"
      if ! {
        printf '%s' "$command_payload" | base64 -d >"${command_file}.tmp" &&
          mv -f "${command_file}.tmp" "$command_file" &&
          chmod 700 "$command_file"
      }; then
        rm -f "${command_file}.tmp" "$command_file"
        return 65
      fi
      _write "$run_dir/starting_deadline" "$(( $(_now) + cleanup_grace ))" || return 74
      _write "$run_dir/state" starting || return 74
      LIFECYCLE_CLEANUP_GRACE_SECONDS="$cleanup_grace"
      export LIFECYCLE_CLEANUP_GRACE_SECONDS
      _supervisor "$run_dir" "$run_id" "$kind" "$owner" "$command_file" "$workspace" </dev/null >"$run_dir/supervisor.log" 2>&1 &
      supervisor_launcher=$!
      disown "$supervisor_launcher" 2>/dev/null || :
      if ! {
        _write "$run_dir/launcher_pid" "$supervisor_launcher" &&
          _write "$run_dir/launcher_identity" "$supervisor_launcher:$run_id" &&
          _write "$run_dir/launcher_start_ticks" "$(_proc_start_ticks "$supervisor_launcher")"
      }; then
        kill "$supervisor_launcher" 2>/dev/null || :
        return 74
      fi
      printf 'started\n'
      ;;
    heartbeat)
      run_dir="$1"; run_id="$2"; lease="$3"; capability="$4"; epoch="${5:-}"
      _verify_run "$run_dir" "$run_id" "$capability" "$epoch" || return $?
      case "$(_read "$run_dir/state")" in terminal|cleanup_failed) return 0;; esac
      _write "$run_dir/lease" "$lease" &&
        _write "$run_dir/last_heartbeat" "$(_now)" &&
        printf 'heartbeat\n'
      ;;
    cancel)
      run_dir="$1"; run_id="$2"; reason="$3"; capability="$4"; epoch="${5:-}"
      _verify_run "$run_dir" "$run_id" "$capability" "$epoch" || return $?
      [[ "$reason" =~ ^[A-Za-z0-9._-]+$ ]] || return 64
      _write "$run_dir/cancel_requested" "$reason" && printf 'cancel_requested\n'
      ;;
    poll)
      run_dir="$1"; run_id="$2"; capability="$3"; epoch="${4:-}"
      _verify_run "$run_dir" "$run_id" "$capability" "$epoch" || return $?
      terminal_snapshot=false
      if [[ -f "$run_dir/terminal.snapshot" && ! -L "$run_dir/terminal.snapshot" ]]; then
        terminal_snapshot=true
        state=$(_snapshot_value state)
      else
        state=$(_read "$run_dir/state")
      fi
      if [[ "$terminal_snapshot" != true &&
        ( "$state" == starting || "$state" == running || "$state" == cleanup || "$state" == recovering ) ]]; then
        _recover_dead_supervisor
      fi
      if [[ "$terminal_snapshot" == true ]]; then
        state=$(_snapshot_value state)
      else
        state=$(_read "$run_dir/state")
      fi
      supervisor_liveness=unknown
      launcher_liveness=unknown
      supervisor_pid=$(_read "$run_dir/supervisor_pid")
      if [[ "$supervisor_pid" =~ ^[0-9]+$ ]] &&
        _proc_matches_ticks "$supervisor_pid" "$run_dir/supervisor_start_ticks"; then
        supervisor_liveness=validated-live
      elif [[ "$state" == running || "$state" == starting ||
        "$state" == terminal || "$state" == cleanup_failed ]]; then
        supervisor_liveness=not-live
      fi
      if [[ "$state" == terminal && "$terminal_snapshot" != true &&
        ( "$(_read "$run_dir/supervisor_done")" != true ||
          "$supervisor_liveness" == validated-live ) ]]; then
        state=cleanup
      fi
      launcher_pid=$(_read "$run_dir/launcher_pid")
      if [[ "$launcher_pid" =~ ^[0-9]+$ ]] &&
        _proc_matches_ticks "$launcher_pid" "$run_dir/launcher_start_ticks"; then
        launcher_liveness=validated-live
      elif [[ "$state" == starting ]]; then
        launcher_liveness=not-live
      fi
      for key in state run_id kind build_id workload_status workload_exit terminal_cause cleanup_status cleanup_cause cleanup_evidence workload_pid workload_pgid supervisor_pid supervisor_identity supervisor_start_ticks supervisor_liveness supervisor_done launcher_pid launcher_start_ticks launcher_liveness supervisor_progress last_heartbeat controller_user workload_user owner_epoch record_sequence terminal_published; do
        if [[ "$terminal_snapshot" == true &&
          "$key" != supervisor_liveness && "$key" != launcher_liveness ]]; then
          value=$(_snapshot_value "$key")
        elif [[ "$key" == record_sequence ]]; then
          value=$(_read "$run_dir/record.sequence")
        else
          value=$(_read "$run_dir/$key")
        fi
        [[ "$key" == supervisor_liveness ]] && value="$supervisor_liveness"
        [[ "$key" == launcher_liveness ]] && value="$launcher_liveness"
        [[ "$key" == state ]] && value="$state"
        [[ "$key" != cleanup_evidence ]] && value=${value//$'\n'/ }
        printf '%s=%s\n' "$key" "$value"
      done
      if [[ "$terminal_snapshot" == true ]]; then
        printf 'record_auth=%s\n' "$(_snapshot_value record_auth)"
      else
        printf 'record_auth=%s\n' "$(_record_tag "$state" "$(_read "$run_dir/workload_status")" \
          "$(_read "$run_dir/workload_exit")" "$(_read "$run_dir/terminal_cause")" \
          "$(_read "$run_dir/cleanup_status")" "$(_read "$run_dir/record.sequence")")"
      fi
      ;;
    collect)
      run_dir="$1"; run_id="$2"; capability="$3"; epoch="${4:-}"
      _verify_run "$run_dir" "$run_id" "$capability" "$epoch" || return $?
      [[ "$(_read "$run_dir/supervisor_done")" == true &&
        -f "$run_dir/terminal.snapshot" && ! -L "$run_dir/terminal.snapshot" ]] || return 75
      supervisor_pid=$(_read "$run_dir/supervisor_pid")
      if [[ "$supervisor_pid" =~ ^[0-9]+$ ]] &&
        _proc_matches_ticks "$supervisor_pid" "$run_dir/supervisor_start_ticks"; then
        return 75
      fi
      for key in run_id kind build_id state workload_status workload_exit terminal_cause cleanup_status cleanup_cause cleanup_evidence workload_pid workload_pgid supervisor_pid supervisor_identity supervisor_start_ticks launcher_pid launcher_start_ticks supervisor_progress supervisor_done controller_user workload_user owner_epoch record_sequence terminal_published; do
        if [[ "$key" == run_id || "$key" == kind || "$key" == build_id || "$key" == state ||
          "$key" == workload_status || "$key" == workload_exit || "$key" == terminal_cause ||
          "$key" == cleanup_status || "$key" == cleanup_evidence || "$key" == owner_epoch ||
          "$key" == record_sequence ]]; then
          value=$(_snapshot_value "$key")
        else
          value=$(_read "$run_dir/$key")
        fi
        value=${value//$'\n'/ }
        value=${value//[^A-Za-z0-9_=,. :\/-]/_}
        printf '%s=%s\n' "$key" "$value"
      done
      printf 'record_auth=%s\n' "$(_snapshot_value record_auth)"
      ;;
    collect_log)
      local log_path log_root log_real
      run_dir="$1"; run_id="$2"; log_name="$3"; capability="$4"; epoch="${5:-}"
      _verify_run "$run_dir" "$run_id" "$capability" "$epoch" || return $?
      case "$log_name" in
        workload|supervisor) ;;
        *) return 64 ;;
      esac
      log_path="${run_dir}/${log_name}.log"
      log_root=$(readlink -f -- "$run_dir") || return 65
      log_real=$(readlink -f -- "$log_path") || return 65
      [[ -f "$log_path" && ! -L "$log_path" && -f "$log_real" &&
        ! -L "$log_real" && "$log_real" == "$log_root/"* ]] || return 65
      cat -- "$log_real"
      ;;
    *) return 64;;
  esac
}

_lifecycle_validate_record_output() {
  local output="$1" run_id state workload_status workload_exit terminal_cause cleanup_status sequence epoch auth expected
  auth=$(printf '%s\n' "$output" | sed -n 's/^record_auth=//p' | tail -n 1)
  [[ -n "$auth" ]] || {
    [[ "${LIFECYCLE_LOCAL_REMOTE:-false}" == true ||
      "$(declare -F lifecycle_remote_provider 2>/dev/null)" != "" ]] && return 0
    return 1
  }
  run_id=$(printf '%s\n' "$output" | sed -n 's/^run_id=//p' | tail -n 1)
  state=$(printf '%s\n' "$output" | sed -n 's/^state=//p' | tail -n 1)
  workload_status=$(printf '%s\n' "$output" | sed -n 's/^workload_status=//p' | tail -n 1)
  workload_exit=$(printf '%s\n' "$output" | sed -n 's/^workload_exit=//p' | tail -n 1)
  terminal_cause=$(printf '%s\n' "$output" | sed -n 's/^terminal_cause=//p' | tail -n 1)
  cleanup_status=$(printf '%s\n' "$output" | sed -n 's/^cleanup_status=//p' | tail -n 1)
  sequence=$(printf '%s\n' "$output" | sed -n 's/^record_sequence=//p' | tail -n 1)
  epoch=$(printf '%s\n' "$output" | sed -n 's/^owner_epoch=//p' | tail -n 1)
  [[ "$run_id" == "$LIFECYCLE_RUN_ID" && "$sequence" =~ ^[0-9]+$ &&
    "$epoch" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ -z "${LIFECYCLE_RECORD_SEQUENCE:-}" || "$sequence" -ge "$LIFECYCLE_RECORD_SEQUENCE" ]] || return 1
  [[ -z "${LIFECYCLE_OWNER_EPOCH:-}" || "$epoch" -ge "$LIFECYCLE_OWNER_EPOCH" ]] || return 1
  expected=$(printf '%s' "$run_id|${LIFECYCLE_RECORD_VERIFIER:-provider-seam}|$sequence|$epoch|$state|$workload_status|$workload_exit|$terminal_cause|$cleanup_status" |
    sha256sum | cut -d' ' -f1)
  [[ "$auth" == "$expected" ]] || return 1
  LIFECYCLE_RECORD_SEQUENCE="$sequence"
  LIFECYCLE_OWNER_EPOCH="$epoch"
  export LIFECYCLE_RECORD_SEQUENCE LIFECYCLE_OWNER_EPOCH
}
_lifecycle_reconcile_start() {
  local run_dir="$1" run_id="$2" deadline="$3" output state supervisor_pid launcher_pid supervisor_ticks supervisor_identity launcher_ticks launcher_identity supervisor_liveness launcher_liveness now remaining
  local previous_retry_deadline="${LIFECYCLE_RETRY_DEADLINE-}"
  export LIFECYCLE_RETRY_DEADLINE="$deadline"
  while (( $(_lifecycle_now) < deadline )); do
    if output=$(_lifecycle_remote_retry poll "$run_dir" "$run_id" \
      "${LIFECYCLE_RECORD_VERIFIER:-provider-seam}" "${LIFECYCLE_OWNER_EPOCH:-1}"); then
      _lifecycle_validate_record_output "$output" || continue
      epoch=$(printf '%s\n' "$output" | sed -n 's/^owner_epoch=//p')
      [[ "$epoch" =~ ^[1-9][0-9]*$ ]] && {
        LIFECYCLE_OWNER_EPOCH="$epoch"
        export LIFECYCLE_OWNER_EPOCH
      }
      state=$(printf '%s\n' "$output" | sed -n 's/^state=//p')
      supervisor_pid=$(printf '%s\n' "$output" | sed -n 's/^supervisor_pid=//p')
      supervisor_ticks=$(printf '%s\n' "$output" | sed -n 's/^supervisor_start_ticks=//p')
      supervisor_identity=$(printf '%s\n' "$output" | sed -n 's/^supervisor_identity=//p')
      supervisor_liveness=$(printf '%s\n' "$output" | sed -n 's/^supervisor_liveness=//p')
      launcher_pid=$(printf '%s\n' "$output" | sed -n 's/^launcher_pid=//p')
      launcher_ticks=$(printf '%s\n' "$output" | sed -n 's/^launcher_start_ticks=//p')
      launcher_identity=$(printf '%s\n' "$output" | sed -n 's/^launcher_identity=//p')
      launcher_liveness=$(printf '%s\n' "$output" | sed -n 's/^launcher_liveness=//p')
      if [[ "$state" == terminal || "$state" == cleanup_failed ||
        ( "$state" == running && "$supervisor_liveness" == validated-live &&
          "$supervisor_pid" =~ ^[0-9]+$ &&
          "$supervisor_ticks" =~ ^[0-9]+$ && "$supervisor_identity" == "$supervisor_pid:$run_id" ) ||
        ( "$state" == starting && "$launcher_liveness" == validated-live &&
          "$launcher_pid" =~ ^[0-9]+$ &&
          "$launcher_ticks" =~ ^[0-9]+$ && "$launcher_identity" == "$launcher_pid:$run_id" ) ]]; then
        LIFECYCLE_LAST_STATE="$output"
        export LIFECYCLE_LAST_STATE
        [[ -n "$previous_retry_deadline" ]] && LIFECYCLE_RETRY_DEADLINE="$previous_retry_deadline" ||
          unset LIFECYCLE_RETRY_DEADLINE
        return 0
      fi
    fi
    now=$(_lifecycle_now)
    remaining=$(( deadline - now ))
    (( remaining > 0 )) && sleep "$(( LIFECYCLE_RECONNECT_DELAY_SECONDS < remaining ? LIFECYCLE_RECONNECT_DELAY_SECONDS : remaining ))"
  done
  [[ -n "$previous_retry_deadline" ]] && LIFECYCLE_RETRY_DEADLINE="$previous_retry_deadline" ||
    unset LIFECYCLE_RETRY_DEADLINE
  return 1
}

_lifecycle_reconcile_reserve() {
  local run_dir="$1" run_id="$2" kind="$3" build_id="$4" deadline="$5" output
  local previous_retry_deadline="${LIFECYCLE_RETRY_DEADLINE-}"
  export LIFECYCLE_RETRY_DEADLINE="$deadline"
  output=$(_lifecycle_remote_retry poll "$run_dir" "$run_id" \
    "${LIFECYCLE_RECORD_VERIFIER:-provider-seam}" "${LIFECYCLE_OWNER_EPOCH:-1}") || {
    [[ -n "$previous_retry_deadline" ]] && LIFECYCLE_RETRY_DEADLINE="$previous_retry_deadline" ||
      unset LIFECYCLE_RETRY_DEADLINE
    return 1
  }
  _lifecycle_validate_record_output "$output" || return 1
  [[ -n "$previous_retry_deadline" ]] && LIFECYCLE_RETRY_DEADLINE="$previous_retry_deadline" ||
    unset LIFECYCLE_RETRY_DEADLINE
  [[ "$(printf '%s\n' "$output" | sed -n 's/^run_id=//p')" == "$run_id" &&
    "$(printf '%s\n' "$output" | sed -n 's/^kind=//p')" == "$kind" &&
    "$(printf '%s\n' "$output" | sed -n 's/^build_id=//p')" == "$build_id" &&
    "$(printf '%s\n' "$output" | sed -n 's/^state=//p')" == reserved ]]

}
_lifecycle_startup_transport_failure() {
  local destination="${ARTIFACT_DIR:-${SHARED_DIR}}"
  mkdir -p "$destination"
  printf 'run_id=%s\noperation=start\nstate=startup_recovery_failed\nremote_record=%s\n' \
    "${LIFECYCLE_RUN_ID:-unknown}" "${LIFECYCLE_RUN_DIR:-unknown}" \
    >"${destination}/nfv-e2e-lifecycle-${LIFECYCLE_RUN_ID:-run}-startup-failure.txt"
}
lifecycle_start() {
  local build_id="${1:-}" kind="${2:-}" workspace="${3:-}" command="${4:-}"; shift 4 || :
  _lifecycle_validate_budget || return 1
  _lifecycle_valid_authority || return 1
  _lifecycle_valid_id "$build_id" || { _lifecycle_die 'invalid build identity'; return 1; }
  _lifecycle_valid_kind "$kind" || { _lifecycle_die 'invalid workload kind'; return 1; }
  _lifecycle_valid_workspace "$workspace" || {
    _lifecycle_die 'invalid remote workspace'
    return 1
  }
  local nonce run_id run_dir lease command_payload arg reserve_output verifier epoch
  local reconcile_deadline recovery_deadline previous_retry_deadline="${LIFECYCLE_RETRY_DEADLINE-}"
  [[ -n "$command" ]] || { _lifecycle_die 'workload command is required'; return 1; }
  nonce=$(_lifecycle_nonce)
  [[ "$nonce" =~ ^[A-Fa-f0-9]{8,64}$ ]] || { _lifecycle_die 'invalid nonce'; return 1; }
  run_id="${kind}-${build_id}-${nonce}"
  local state_root="${LIFECYCLE_STATE_ROOT:-${workspace}/.nfv-e2e-lifecycle}"
  _lifecycle_valid_workspace "$state_root" || { _lifecycle_die 'invalid lifecycle state root'; return 1; }
  run_dir="${state_root}/${run_id}"
  lease=$(( $(_lifecycle_now) + LIFECYCLE_LEASE_SECONDS ))
  command_payload=$(printf 'exec %q' "$command")
  for arg in "$@"; do command_payload+=" $(printf '%q' "$arg")"; done
  command_payload=$(printf '%s' "$command_payload" | base64 | tr -d '\n')
  LIFECYCLE_RUN_ID="$run_id"; LIFECYCLE_RUN_DIR="$run_dir"; LIFECYCLE_KIND="$kind"
  LIFECYCLE_CANCEL_FAILED=false
  export LIFECYCLE_RUN_ID LIFECYCLE_RUN_DIR LIFECYCLE_KIND LIFECYCLE_CANCEL_FAILED
  if reserve_output=$(_lifecycle_remote_retry reserve "$run_dir" "$run_id" "$kind" "$build_id" "$lease" "$workspace"); then
    verifier=$(printf '%s\n' "$reserve_output" | sed -n 's/^reserved verifier=\([^ ]*\).*$/\1/p')
    epoch=$(printf '%s\n' "$reserve_output" | sed -n 's/^reserved verifier=[^ ]* epoch=\([0-9][0-9]*\).*$/\1/p')
    if [[ -z "$verifier" ]]; then
      if [[ "${LIFECYCLE_LOCAL_REMOTE:-false}" != true ]] &&
        ! declare -F lifecycle_remote_provider >/dev/null 2>&1; then
        _lifecycle_die 'controller reservation did not return a verifier'
        return 1
      fi
      verifier="provider-seam-${nonce}"
    fi
    [[ "$epoch" =~ ^[1-9][0-9]*$ ]] || epoch=1
    LIFECYCLE_RECORD_VERIFIER="$verifier"
    LIFECYCLE_OWNER_EPOCH="$epoch"
    export LIFECYCLE_RECORD_VERIFIER LIFECYCLE_OWNER_EPOCH
    LIFECYCLE_RECORD_SEQUENCE=0
    export LIFECYCLE_RECORD_SEQUENCE
  else
    reconcile_deadline=$(( $(_lifecycle_now) + LIFECYCLE_CLEANUP_GRACE_SECONDS ))
    if ! _lifecycle_reconcile_reserve "$run_dir" "$run_id" "$kind" "$build_id" "$reconcile_deadline"; then
      _lifecycle_startup_transport_failure
      _lifecycle_die 'run identity reservation failed'
      return 1
    fi
  fi
  if ! _lifecycle_remote_retry start "$run_dir" "$run_id" "$kind" "$command_payload" \
    "$LIFECYCLE_RECORD_VERIFIER" "$LIFECYCLE_CLEANUP_GRACE_SECONDS" "$workspace" >/dev/null; then
    reconcile_deadline=$(( $(_lifecycle_now) + LIFECYCLE_CLEANUP_GRACE_SECONDS ))
    if ! _lifecycle_reconcile_start "$run_dir" "$run_id" "$reconcile_deadline"; then
      recovery_deadline=$(_lifecycle_recovery_deadline)
      export LIFECYCLE_RETRY_DEADLINE="$recovery_deadline"
      _lifecycle_remote_retry cancel "$run_dir" "$run_id" startup_failed \
        "$LIFECYCLE_RECORD_VERIFIER" "$LIFECYCLE_OWNER_EPOCH" >/dev/null 2>&1 ||
        _lifecycle_transport_failure startup_cancel
      _lifecycle_wait_recover "$run_dir" startup_failed "$previous_retry_deadline" 1 "$recovery_deadline" || :
      _lifecycle_startup_transport_failure
      _lifecycle_restore_retry_deadline "$previous_retry_deadline"
      return 1
    fi
  fi
  printf '%s\n' "$run_id"
}

lifecycle_heartbeat() {
  local run_dir="${1:-${LIFECYCLE_RUN_DIR}}"
  [[ -n "$run_dir" ]] || { _lifecycle_die 'run is not started'; return 1; }
  _lifecycle_remote_retry heartbeat "$run_dir" "${LIFECYCLE_RUN_ID}" \
    "$(( $(_lifecycle_now) + LIFECYCLE_LEASE_SECONDS ))" \
    "${LIFECYCLE_RECORD_VERIFIER:-provider-seam}" "${LIFECYCLE_OWNER_EPOCH:-1}" >/dev/null
}

lifecycle_poll() {
  local run_dir="${1:-${LIFECYCLE_RUN_DIR}}" output
  [[ -n "$run_dir" ]] || { _lifecycle_die 'run is not started'; return 1; }
  output=$(_lifecycle_remote_retry poll "$run_dir" "${LIFECYCLE_RUN_ID}" \
    "${LIFECYCLE_RECORD_VERIFIER:-provider-seam}" "${LIFECYCLE_OWNER_EPOCH:-1}") || return $?
  _lifecycle_validate_record_output "$output" || {
    _lifecycle_die 'unauthenticated lifecycle record'
    return 1
  }
  LIFECYCLE_LAST_STATE="$output"
  export LIFECYCLE_LAST_STATE
  printf '%s\n' "$output"
}

lifecycle_cancel() {
  local reason="${1:-cancelled}" run_dir="${2:-${LIFECYCLE_RUN_DIR}}" status
  [[ "$reason" =~ ^[A-Za-z0-9._-]+$ ]] || { _lifecycle_die 'invalid cancellation reason'; return 1; }
  [[ -n "$run_dir" ]] || { _lifecycle_die 'run is not started'; return 1; }
  if _lifecycle_remote_retry cancel "$run_dir" "${LIFECYCLE_RUN_ID}" "$reason" \
    "${LIFECYCLE_RECORD_VERIFIER:-provider-seam}" "${LIFECYCLE_OWNER_EPOCH:-1}" >/dev/null; then
    LIFECYCLE_CANCEL_FAILED=false
    export LIFECYCLE_CANCEL_FAILED
    return 0
  else
    status=$?
  fi
  LIFECYCLE_CANCEL_FAILED=true
  export LIFECYCLE_CANCEL_FAILED
  return "$status"
}
_lifecycle_transport_failure() {
  local operation="$1" destination="${ARTIFACT_DIR:-${SHARED_DIR}}" safe_operation
  safe_operation="${operation//[^A-Za-z0-9_.-]/_}"
  mkdir -p "$destination"
  printf 'run_id=%s\noperation=%s\nremote_record=%s\n' \
    "${LIFECYCLE_RUN_ID:-unknown}" "$operation" "${LIFECYCLE_RUN_DIR:-unknown}" \
    >"${destination}/nfv-e2e-lifecycle-${LIFECYCLE_RUN_ID:-run}-transport-failure-${safe_operation}.txt"
}
_lifecycle_timeout_cancel() {
  local run_dir="$1" previous_retry_deadline="$2" recovery_deadline result=1
  recovery_deadline=$(_lifecycle_recovery_deadline)
  export LIFECYCLE_RETRY_DEADLINE="$recovery_deadline"
  lifecycle_cancel wait_timeout >/dev/null 2>&1 || _lifecycle_transport_failure wait_timeout_cancel
  _lifecycle_wait_recover "$run_dir" wait_timeout "$previous_retry_deadline" 1 "$recovery_deadline" ||
    result=$?
  _lifecycle_restore_retry_deadline "$previous_retry_deadline"
  return "$result"
}

_lifecycle_recovery_deadline() {
  printf '%s\n' "$(( $(_lifecycle_now) + LIFECYCLE_CLEANUP_GRACE_SECONDS +
    LIFECYCLE_OPERATION_TIMEOUT_SECONDS * LIFECYCLE_RECONNECT_ATTEMPTS +
    LIFECYCLE_RECONNECT_DELAY_SECONDS * (LIFECYCLE_RECONNECT_ATTEMPTS - 1) ))"
}
_lifecycle_sanitize_log() {
  awk '
    BEGIN { redact_block = 0 }
    {
      if (redact_block) {
        if ($0 ~ /^[[:space:]]/ || $0 ~ /^[[:space:]]*$/) {
          print "<REDACTED BLOCK>"
          next
        }
        redact_block = 0
      }
      lower = tolower($0)
      if (lower ~ /(^|[^[:alnum:]_])(password|passwd|token|secret|api[-_]?key|private[-_]?key|authorization)[[:space:]]*:[[:space:]]*(\||>)[+-]?[0-9]*[[:space:]]*$/ ||
          lower ~ /(^|[^[:alnum:]_])(password|passwd|token|secret|api[-_]?key|private[-_]?key|authorization)[[:space:]]*:[[:space:]]*$/) {
        sub(/:[[:space:]]*.*$/, ": <REDACTED>")
        print
        redact_block = 1
        next
      }
      print
    }
  ' | sed -E \
    -e '/-----BEGIN .*PRIVATE KEY-----/,/-----END .*PRIVATE KEY-----/ s/.*/<REDACTED PRIVATE KEY>/I' \
    -e "s/([\"']?[[:space:]]*(password|passwd|token|secret|api[-_]?key|private[-_]?key|authorization|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY)([-_][[:alnum:]_-]+)?[\"']?[[:space:]]*[:=][[:space:]]*)[\"'][^\"']*[\"']/\1<REDACTED>/Ig" \
    -e 's/((AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY))[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1<REDACTED>/Ig' \
    -e 's/(Bearer[[:space:]]+|Basic[[:space:]]+)[^[:space:]]+/\1<REDACTED>/Ig' \
    -e 's/((password|passwd|token|secret|api[-_]?key|private[-_]?key|authorization)[[:space:]]*:[[:space:]]*)[^[:space:],}]+/\1<REDACTED>/Ig' \
    -e 's/("[[:space:]]*(password|passwd|token|secret|api[-_]?key|private[-_]?key|authorization)[[:space:]]*"[:=][[:space:]]*")[^"]*"/\1<REDACTED>"/Ig' \
    -e 's#(https?://[^/:[:space:]]+):[^@[:space:]]+@#\1:<REDACTED>@#Ig' \
    -e 's/(-u[[:space:]]+[^:[:space:]]+):[^[:space:]]+/\1:<REDACTED>/Ig' \
    -e 's/(client-key-data:[[:space:]]*).*/\1<REDACTED>/Ig' \
    -e 's/(^|[^[:alnum:]_])([A-Za-z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE[_-]?KEY|API[_-]?KEY|ACCESS[_-]?KEY)[A-Za-z0-9_-]*)[[:space:]]*=[[:space:]]*[^[:space:]]+/\1\2=<REDACTED>/Ig' \
    -e 's/((--)?(password|passwd|token|secret|api[-_]?key|private[-_]?key|authorization)[[:space:]]*=[[:space:]]*)[^[:space:]]+/\1<REDACTED>/Ig' \
    -e 's/((--)?(password|passwd|token|secret|api[-_]?key|private[-_]?key|authorization)[[:space:]]+)[^[:space:]]+/\1<REDACTED>/Ig'
}

_lifecycle_recover_terminal() {
  local run_dir="$1" deadline="$2" output state remaining
  local previous_retry_deadline="${LIFECYCLE_RETRY_DEADLINE-}"
  export LIFECYCLE_RETRY_DEADLINE="$deadline"
  while (( $(_lifecycle_now) < deadline )); do
    if output=$(lifecycle_poll "$run_dir"); then
      state=$(printf '%s\n' "$output" | sed -n 's/^state=//p')
      if [[ "$state" == terminal || "$state" == cleanup_failed ]]; then
        LIFECYCLE_LAST_STATE="$output"
        export LIFECYCLE_LAST_STATE
        [[ -n "$previous_retry_deadline" ]] && LIFECYCLE_RETRY_DEADLINE="$previous_retry_deadline" ||
          unset LIFECYCLE_RETRY_DEADLINE
        return 0
      fi
    fi
    remaining=$(( deadline - $(_lifecycle_now) ))
    (( remaining > 0 )) || break
    sleep "$(( LIFECYCLE_POLL_SECONDS < remaining ? LIFECYCLE_POLL_SECONDS : remaining ))"
  done
  [[ -n "$previous_retry_deadline" ]] && LIFECYCLE_RETRY_DEADLINE="$previous_retry_deadline" ||
    unset LIFECYCLE_RETRY_DEADLINE
  return 1
}

_lifecycle_collect_until() {
  local run_dir="$1" deadline="$2" remaining
  local previous_retry_deadline="${LIFECYCLE_RETRY_DEADLINE-}"
  export LIFECYCLE_RETRY_DEADLINE="$deadline"
  while (( $(_lifecycle_now) < deadline )); do
    if lifecycle_collect "$run_dir"; then
      [[ -n "$previous_retry_deadline" ]] && LIFECYCLE_RETRY_DEADLINE="$previous_retry_deadline" ||
        unset LIFECYCLE_RETRY_DEADLINE
      return 0
    fi
    remaining=$(( deadline - $(_lifecycle_now) ))
    (( remaining > 0 )) || break
    sleep "$(( LIFECYCLE_RECONNECT_DELAY_SECONDS < remaining ? LIFECYCLE_RECONNECT_DELAY_SECONDS : remaining ))"
  done
  [[ -n "$previous_retry_deadline" ]] && LIFECYCLE_RETRY_DEADLINE="$previous_retry_deadline" ||
    unset LIFECYCLE_RETRY_DEADLINE
  return 1
}

_lifecycle_finish_wait() {
  local run_dir="$1" deadline="$2" output workload_exit cleanup_status terminal_cause supervisor_done supervisor_liveness
  _lifecycle_collect_until "$run_dir" "$deadline" || return 1
  output="${LIFECYCLE_LAST_STATE}"
  workload_exit=$(printf '%s\n' "$output" | sed -n 's/^workload_exit=//p')
  cleanup_status=$(printf '%s\n' "$output" | sed -n 's/^cleanup_status=//p')
  terminal_cause=$(printf '%s\n' "$output" | sed -n 's/^terminal_cause=//p')
  supervisor_done=$(printf '%s\n' "$output" | sed -n 's/^supervisor_done=//p')
  supervisor_liveness=$(printf '%s\n' "$output" | sed -n 's/^supervisor_liveness=//p')
  LIFECYCLE_RESULT=0
  [[ "$terminal_cause" == completion && "$cleanup_status" == verified &&
    "${workload_exit:-1}" == 0 ]] || LIFECYCLE_RESULT=1
  if [[ -n "$supervisor_done" &&
    ( "$supervisor_done" != true || "$supervisor_liveness" == validated-live ) ]]; then
    LIFECYCLE_RESULT=1
  fi
  return 0
}
_lifecycle_restore_retry_deadline() {
  local previous="$1"
  [[ -n "$previous" ]] && LIFECYCLE_RETRY_DEADLINE="$previous" ||
    unset LIFECYCLE_RETRY_DEADLINE
}
_lifecycle_wait_recover() {
  local run_dir="$1" operation="$2" previous_retry_deadline="$3" initial_status="${4:-1}" recovery_deadline="${5:-}"
  _lifecycle_transport_failure "$operation"
  local result
  [[ -n "$recovery_deadline" ]] || recovery_deadline=$(_lifecycle_recovery_deadline)
  export LIFECYCLE_RETRY_DEADLINE="$recovery_deadline"
  if _lifecycle_recover_terminal "$run_dir" "$recovery_deadline" &&
    _lifecycle_finish_wait "$run_dir" "$recovery_deadline"; then
    result="$LIFECYCLE_RESULT"
  else
    _lifecycle_transport_failure "${operation}_recovery"
    result="${LIFECYCLE_LAST_REMOTE_STATUS:-$initial_status}"
    [[ "$result" == 1 && "$initial_status" != 1 ]] && result="$initial_status"
  fi
  _lifecycle_restore_retry_deadline "$previous_retry_deadline"
  return "$result"
}


lifecycle_wait() {
  local run_dir="${1:-${LIFECYCLE_RUN_DIR}}" output state deadline now remaining timeout_failed=false
  local previous_retry_deadline="${LIFECYCLE_RETRY_DEADLINE-}" recovery_deadline result cancel_failed=false
  [[ -n "$run_dir" ]] || { _lifecycle_die 'run is not started'; return 1; }
  deadline=$(( $(_lifecycle_now) + LIFECYCLE_WAIT_TIMEOUT_SECONDS ))
  export LIFECYCLE_RETRY_DEADLINE="$deadline"
  while :; do
    if [[ -n "${LIFECYCLE_SIGNAL_FILE:-}" && -f "${LIFECYCLE_SIGNAL_FILE}" ]]; then
      recovery_deadline=$(_lifecycle_recovery_deadline)
      if [[ "${LIFECYCLE_CANCEL_FAILED:-false}" != true ]] &&
        ! lifecycle_cancel prow_signal >/dev/null 2>&1; then
        cancel_failed=true
        _lifecycle_transport_failure signal_cancel
      fi
      _lifecycle_wait_recover "$run_dir" signal "$previous_retry_deadline" 1 "$recovery_deadline" || result=$?
      _lifecycle_restore_retry_deadline "$previous_retry_deadline"
      return 1
    fi
    now=$(_lifecycle_now)
    if (( now >= deadline )); then
      timeout_failed=true
      recovery_deadline=$(_lifecycle_recovery_deadline)
      export LIFECYCLE_RETRY_DEADLINE="$recovery_deadline"
      if ! lifecycle_cancel wait_timeout >/dev/null 2>&1; then
        cancel_failed=true
        _lifecycle_transport_failure wait_timeout_cancel
      fi
      _lifecycle_wait_recover "$run_dir" wait_timeout "$previous_retry_deadline" 1 "$recovery_deadline"
      result=$?
      [[ "$timeout_failed" == true || "$cancel_failed" == true ]] && return 1
      return "$result"
    fi
    if [[ "${LIFECYCLE_CANCEL_FAILED:-false}" == true ]]; then
      :
    elif lifecycle_heartbeat "$run_dir"; then
      :
    else
      result=$?
      _lifecycle_wait_recover "$run_dir" heartbeat "$previous_retry_deadline" "$result"
      return $?
    fi
    now=$(_lifecycle_now)
    if (( now >= deadline )); then
      _lifecycle_timeout_cancel "$run_dir" "$previous_retry_deadline" || :
      return 1
    fi
    if output=$(lifecycle_poll "$run_dir"); then
      :
    else
      result=$?
      if (( $(_lifecycle_now) >= deadline )); then
        _lifecycle_timeout_cancel "$run_dir" "$previous_retry_deadline" || :
        return 1
      fi
      if [[ "$result" == 17 ]]; then
        _lifecycle_restore_retry_deadline "$previous_retry_deadline"
        return "$result"
      fi
      _lifecycle_wait_recover "$run_dir" poll "$previous_retry_deadline" "$result"
      return $?
    fi
    LIFECYCLE_LAST_STATE="$output"
    export LIFECYCLE_LAST_STATE
    state=$(printf '%s\n' "$output" | sed -n 's/^state=//p')
    if (( $(_lifecycle_now) >= deadline )) &&
      [[ "$state" != terminal && "$state" != cleanup_failed ]]; then
      _lifecycle_timeout_cancel "$run_dir" "$previous_retry_deadline" || :
      return 1
    fi
    if [[ "$state" == terminal || "$state" == cleanup_failed ]]; then
      recovery_deadline=$(_lifecycle_recovery_deadline)
      if _lifecycle_finish_wait "$run_dir" "$recovery_deadline"; then
        result="$LIFECYCLE_RESULT"
      else
        _lifecycle_transport_failure collect
        result=1
      fi
      _lifecycle_restore_retry_deadline "$previous_retry_deadline"
      return "$result"
    fi
    remaining=$(( deadline - $(_lifecycle_now) ))
    (( remaining > 0 )) || continue
    sleep "$(( LIFECYCLE_POLL_SECONDS < remaining ? LIFECYCLE_POLL_SECONDS : remaining ))"
  done
}

lifecycle_collect() (
  local run_dir="${1:-${LIFECYCLE_RUN_DIR}}" destination="${2:-${ARTIFACT_DIR:-${SHARED_DIR}}}"
  local final_base staging_dir log_name log_file raw_file sanitized_file
  [[ -n "$run_dir" ]] || {
    _lifecycle_die 'run is not started'
    return 1
  }
  mkdir -p "$destination"
  final_base="${destination}/nfv-e2e-lifecycle-${LIFECYCLE_RUN_ID:-run}"
  _lifecycle_remote_retry --file "${final_base}.txt" collect "$run_dir" "${LIFECYCLE_RUN_ID}" \
    "${LIFECYCLE_RECORD_VERIFIER:-provider-seam}" "${LIFECYCLE_OWNER_EPOCH:-1}" || return 1
  _lifecycle_validate_record_output "$(<"${final_base}.txt")" || {
    _lifecycle_die 'unauthenticated lifecycle record'
    return 1
  }
  staging_dir=$(mktemp -d "${destination}/.nfv-e2e-lifecycle.XXXXXX") || return 1
  trap 'rm -rf "$staging_dir"' EXIT
  for log_name in workload supervisor; do
    log_file="${final_base}-${log_name}.log"
    raw_file="${staging_dir}/${log_name}.raw"
    sanitized_file="${staging_dir}/${log_name}.log"
    _lifecycle_remote_retry --file "$raw_file" collect_log "$run_dir" "${LIFECYCLE_RUN_ID}" \
      "$log_name" "${LIFECYCLE_RECORD_VERIFIER:-provider-seam}" \
      "${LIFECYCLE_OWNER_EPOCH:-1}" || return 1
    _lifecycle_sanitize_log <"$raw_file" >"$sanitized_file" || return 1
    mv -f "$sanitized_file" "$log_file" || return 1
  done
)
LIFECYCLE_HELPER
chmod 700 "${helper}"
printf 'Generated NFV E2E lifecycle helper at %s\n' "${helper}"
