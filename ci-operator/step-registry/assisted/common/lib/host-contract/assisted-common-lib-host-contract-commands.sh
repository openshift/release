#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

machine_conf="${SHARED_DIR}/ci-machine-config.sh"

if [[ -s "${machine_conf}" ]]; then
  exit 0
fi

packet_conf="${SHARED_DIR}/packet-conf.sh"
cir_file="${SHARED_DIR}/cir"
ssh_key_default="${CLUSTER_PROFILE_DIR}/packet-ssh-key"

if [[ ! -f "${packet_conf}" ]]; then
  echo "Error: ${machine_conf} missing and packet-conf.sh not present; cannot derive host contract" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${packet_conf}"

ip_value="${IP:-}"
if [[ -z "${ip_value}" && -f "${cir_file}" ]]; then
  ip_value="$(jq -r '.ip // empty' "${cir_file}" || true)"
fi

if [[ -z "${ip_value}" ]]; then
  echo "Error: Unable to determine IP address from packet-conf or cir file" >&2
  exit 1
fi

ssh_user="${SSH_USER:-root}"
ssh_key_file="${SSH_KEY_FILE:-${ssh_key_default}}"
if [[ ! -f "${ssh_key_file}" ]]; then
  echo "Error: SSH key file not found at ${ssh_key_file}" >&2
  exit 1
fi

ssh_port="${SSH_PORT:-}"
if [[ -z "${ssh_port}" ]]; then
  if [[ -n "${PORT:-}" ]]; then
    ssh_port="${PORT}"
  else
    ssh_port="22"
  fi
fi

cat > "${machine_conf}" <<'EOF'
export IP="${ip_value}"
export SSH_USER="${ssh_user}"
export SSH_KEY_FILE="${ssh_key_file}"
export SSH_PORT="${ssh_port}"
EOF
