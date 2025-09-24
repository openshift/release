#!/usr/bin/env bash
#
# Assisted Host Provider Contract helper library.
#
# This library centralises the contract between provider specific host
# acquisition steps (e.g. OFCIR, Nutanix, vSphere) and generic Assisted
# Installer workflows. Providers populate a contract file with standardised
# variables, and consumer steps source that contract to obtain connection
# metadata in a provider agnostic way.
#
# The contract file is a shell fragment containing "export KEY=value" lines.
# By default the file lives at "${SHARED_DIR}/host-contract.sh", but callers
# can override HOST_CONTRACT_PATH before sourcing this helper.
#
# Minimal contract keys (must be provided by the writer):
#   HOST_PROVIDER                     - Provider identifier (e.g. ofcir, nutanix)
#   HOST_PRIMARY_IP                   - Reachable IP/FQDN of the primary host
#   HOST_PRIMARY_SSH_USER             - SSH username for the primary host
#   HOST_PRIMARY_SSH_KEY_PATH         - Path to the SSH private key on the step host
#
# Optional keys (defaults listed where applicable):
#   HOST_PRIMARY_NAME                 - Logical name (default: "primary")
#   HOST_PRIMARY_SSH_PORT             - SSH port (default: 22)
#   HOST_PRIMARY_SSH_ADDITIONAL_OPTIONS - Extra ssh/scp options (space separated)
#   HOST_PRIMARY_SSH_KNOWN_HOSTS      - Path to a pre-populated known_hosts file
#   HOST_PRIMARY_SSH_BASTION          - ssh:// style URI for a bastion jump host
#   HOST_PRIMARY_METADATA_PATH        - Path to provider metadata JSON/YAML
#   HOST_PRIMARY_ENV_PATH             - Path to provider specific env file
#
# The helper exposes writer utilities (for providers) and loader utilities
# (for steps that consume the host). See README.md next to this file for usage.

set -euo pipefail

HOST_CONTRACT_PATH="${HOST_CONTRACT_PATH:-}"
HOST_CONTRACT_WRITER_FILE="${HOST_CONTRACT_WRITER_FILE:-}"

_host_contract::default_path() {
    local shared_dir="${SHARED_DIR:-}"
    if [[ -n "${HOST_CONTRACT_PATH:-}" ]]; then
        printf '%s\n' "$HOST_CONTRACT_PATH"
    elif [[ -n "$shared_dir" ]]; then
        printf '%s\n' "${shared_dir%/}/host-contract.sh"
    else
        printf '%s\n' "${PWD}/host-contract.sh"
    fi
}

_host_contract::ensure_dir() {
    local file="$1"
    local dir
    dir="$(dirname "$file")"
    mkdir -p "$dir"
}

_host_contract::require_var() {
    local name="$1"
    local value="${!name:-}"
    if [[ -z "$value" ]]; then
        printf 'host-contract: required variable %s missing in %s\n' "$name" "${HOST_CONTRACT_PATH}" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Writer helpers (provider side)
# ---------------------------------------------------------------------------

host_contract::writer::begin() {
    local dest="${1:-$(_host_contract::default_path)}"
    _host_contract::ensure_dir "$dest"
    HOST_CONTRACT_PATH="$dest"
    HOST_CONTRACT_WRITER_FILE="$dest"
    cat >"$dest" <<'WRITER'
#!/usr/bin/env bash
# Generated Assisted host provider contract
# shellcheck disable=SC2034
WRITER
}

host_contract::writer::set() {
    if [[ $# -ne 2 ]]; then
        printf 'host-contract writer requires key and value (got %s arguments)\n' "$#" >&2
        return 1
    fi
    if [[ -z "${HOST_CONTRACT_WRITER_FILE:-}" ]]; then
        printf 'host-contract: writer not initialised. Call host_contract::writer::begin first.\n' >&2
        return 1
    fi
    local key="$1"
    local value="$2"
    printf 'export %s=%q\n' "$key" "$value" >>"$HOST_CONTRACT_WRITER_FILE"
}

host_contract::writer::unset() {
    if [[ $# -ne 1 ]]; then
        printf 'host-contract writer unset needs a key\n' >&2
        return 1
    fi
    if [[ -z "${HOST_CONTRACT_WRITER_FILE:-}" ]]; then
        printf 'host-contract: writer not initialised. Call host_contract::writer::begin first.\n' >&2
        return 1
    fi
    local key="$1"
    printf 'unset %s\n' "$key" >>"$HOST_CONTRACT_WRITER_FILE"
}

host_contract::writer::commit() {
    if [[ -z "${HOST_CONTRACT_WRITER_FILE:-}" ]]; then
        printf 'host-contract: nothing to commit. Did you call host_contract::writer::begin?\n' >&2
        return 1
    fi
    chmod 0600 "$HOST_CONTRACT_WRITER_FILE"
}

# ---------------------------------------------------------------------------
# Loader helpers (consumer side)
# ---------------------------------------------------------------------------

host_contract::path() {
    if [[ -n "${HOST_CONTRACT_PATH:-}" ]]; then
        printf '%s\n' "$HOST_CONTRACT_PATH"
        return 0
    fi
    HOST_CONTRACT_PATH="$(_host_contract::default_path)"
    printf '%s\n' "$HOST_CONTRACT_PATH"
}

host_contract::require() {
    local path
    path="$(host_contract::path)"
    if [[ ! -f "$path" ]]; then
        printf 'host-contract: contract not found at %s\n' "$path" >&2
        return 1
    fi
}

host_contract::load() {
    host_contract::require
    # shellcheck disable=SC1090
    source "$(host_contract::path)"
    HOST_CONTRACT_PATH="$(host_contract::path)"

    _host_contract::require_var HOST_PROVIDER
    _host_contract::require_var HOST_PRIMARY_IP
    _host_contract::require_var HOST_PRIMARY_SSH_USER
    _host_contract::require_var HOST_PRIMARY_SSH_KEY_PATH

    export HOST_PRIMARY_NAME="${HOST_PRIMARY_NAME:-primary}"
    export HOST_PRIMARY_SSH_PORT="${HOST_PRIMARY_SSH_PORT:-22}"
    export HOST_PRIMARY_SSH_KNOWN_HOSTS="${HOST_PRIMARY_SSH_KNOWN_HOSTS:-}"
    export HOST_PRIMARY_SSH_BASTION="${HOST_PRIMARY_SSH_BASTION:-}"
    export HOST_PRIMARY_METADATA_PATH="${HOST_PRIMARY_METADATA_PATH:-}"
    export HOST_PRIMARY_ENV_PATH="${HOST_PRIMARY_ENV_PATH:-}"

    declare -g HOST_SSH_HOST="$HOST_PRIMARY_IP"
    declare -g HOST_SSH_USER="$HOST_PRIMARY_SSH_USER"
    declare -g HOST_SSH_PORT="$HOST_PRIMARY_SSH_PORT"
    declare -g HOST_SSH_KEY_FILE="$HOST_PRIMARY_SSH_KEY_PATH"

    local default_opts='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR -o ConnectTimeout=5'
    declare -g -a HOST_SSH_COMMON_OPTIONS
    # shellcheck disable=SC2206
    HOST_SSH_COMMON_OPTIONS=( ${HOST_PRIMARY_SSH_ADDITIONAL_OPTIONS:-$default_opts} )

    declare -g -a HOST_SSH_OPTIONS
    HOST_SSH_OPTIONS=( "-p" "$HOST_SSH_PORT" "-i" "$HOST_SSH_KEY_FILE" )
    HOST_SSH_OPTIONS+=( "${HOST_SSH_COMMON_OPTIONS[@]}" )

    if [[ -n "$HOST_PRIMARY_SSH_KNOWN_HOSTS" ]]; then
        HOST_SSH_OPTIONS+=( "-o" "UserKnownHostsFile=$HOST_PRIMARY_SSH_KNOWN_HOSTS" )
        HOST_SSH_OPTIONS+=( "-o" "StrictHostKeyChecking=yes" )
    fi

    export HOST_CONTRACT_READY=1
}

host_contract::ensure_loaded() {
    if [[ "${HOST_CONTRACT_READY:-0}" != "1" ]]; then
        host_contract::load
    fi
}

host_contract::write_inventory() {
    host_contract::ensure_loaded
    local dest="${1:-${SHARED_DIR:-./}/inventory}"
    _host_contract::ensure_dir "$dest"
    local common_args="${HOST_SSH_COMMON_OPTIONS[*]}"
    cat >"$dest" <<EOF
[${HOST_PRIMARY_NAME}]
${HOST_PRIMARY_NAME} ansible_host=${HOST_PRIMARY_IP} ansible_user=${HOST_PRIMARY_SSH_USER} ansible_ssh_user=${HOST_PRIMARY_SSH_USER} ansible_ssh_private_key_file=${HOST_PRIMARY_SSH_KEY_PATH} ansible_port=${HOST_PRIMARY_SSH_PORT} ansible_ssh_common_args='${common_args}'
EOF
}

host_contract::write_ansible_cfg() {
    host_contract::ensure_loaded
    local dest="${1:-${SHARED_DIR:-./}/ansible.cfg}"
    _host_contract::ensure_dir "$dest"
    cat >"$dest" <<'ANSIBLE'
[defaults]
callback_whitelist = profile_tasks
host_key_checking = False
stdout_callback = yaml
bin_ansible_callbacks = True

[ssh_connection]
retries = 10
ANSIBLE
}

host_contract::write_ssh_config() {
    host_contract::ensure_loaded
    local dest="${1:-${SHARED_DIR:-./}/ssh_config}"
    local alias="${2:-ci_machine}"
    _host_contract::ensure_dir "$dest"
    cat >"$dest" <<EOF
Host ${alias}
  HostName ${HOST_PRIMARY_IP}
  User ${HOST_PRIMARY_SSH_USER}
  Port ${HOST_PRIMARY_SSH_PORT}
  IdentityFile ${HOST_PRIMARY_SSH_KEY_PATH}
  ConnectTimeout 5
  ServerAliveInterval 90
  LogLevel ERROR
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
EOF
    if [[ -n "$HOST_PRIMARY_SSH_BASTION" ]]; then
        printf '  ProxyJump %s\n' "$HOST_PRIMARY_SSH_BASTION" >>"$dest"
    fi
}

host_contract::ssh() {
    host_contract::ensure_loaded
    if [[ $# -lt 1 ]]; then
        printf 'host-contract ssh: command required\n' >&2
        return 1
    fi
    local cmd=("$@")
    ssh "${HOST_SSH_OPTIONS[@]}" "${HOST_PRIMARY_SSH_USER}@${HOST_PRIMARY_IP}" "${cmd[@]}"
}

host_contract::scp_to_host() {
    host_contract::ensure_loaded
    if [[ $# -lt 2 ]]; then
        printf 'host-contract scp_to_host: usage <src>... <dest>\n' >&2
        return 1
    fi
    local dest="${@: -1}"
    local src=("${@:1:$#-1}")
    scp "${HOST_SSH_OPTIONS[@]}" "${src[@]}" "${HOST_PRIMARY_SSH_USER}@${HOST_PRIMARY_IP}:${dest}"
}

host_contract::scp_from_host() {
    host_contract::ensure_loaded
    if [[ $# -ne 2 ]]; then
        printf 'host-contract scp_from_host: usage <src> <dest>\n' >&2
        return 1
    fi
    local src="$1"
    local dest="$2"
    scp "${HOST_SSH_OPTIONS[@]}" "${HOST_PRIMARY_SSH_USER}@${HOST_PRIMARY_IP}:${src}" "$dest"
}

