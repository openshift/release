#!/usr/bin/env bash

# Load and validate the assisted host contract emitted by provider steps.
# Requires $SHARED_DIR to be set. Exports IP, SSH_USER, SSH_KEY_FILE (if provided),
# SSH_PORT (default 22) and REMOTE_TARGET ("${SSH_USER}@${IP}").
assisted_load_host_contract() {
  local machine_conf="${SHARED_DIR}/ci-machine-config.sh"

  if [[ ! -f "${machine_conf}" ]]; then
    echo "Error: ci-machine-config.sh not found at ${machine_conf}" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "${machine_conf}"

  if [[ -z "${IP:-}" ]]; then
    echo "Error: IP not defined in ${machine_conf}" >&2
    return 1
  fi

  SSH_USER="${SSH_USER:-root}"
  SSH_PORT="${SSH_PORT:-22}"

  if [[ -n "${SSH_KEY_FILE:-}" ]]; then
    if [[ ! -f "${SSH_KEY_FILE}" ]]; then
      echo "Error: SSH key file not found at ${SSH_KEY_FILE}" >&2
      return 1
    fi
    export SSH_KEY_FILE
  fi

  export IP
  export SSH_USER
  export SSH_PORT
  export REMOTE_TARGET="${SSH_USER}@${IP}"
}

# If executed directly, perform a no-op load as a sanity check.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  assisted_load_host_contract
fi
