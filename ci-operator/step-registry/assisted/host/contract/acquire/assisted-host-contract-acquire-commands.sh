#!/bin/bash
set -euo pipefail

: "${SHARED_DIR?must be set}"

# Default to Prow/ofcir behavior unless explicitly running locally
if [[ "${HOST_CONTRACT_LOCAL:-}" != "true" ]]; then
  # Running in Prow - delegate to ofcir-acquire
  echo "[host-contract] Running in Prow environment - delegating to ofcir-acquire"

  SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]:-$0}")
  STEP_ROOT=$(realpath "$(dirname "${SCRIPT_PATH}")/../../../..")
  OFCIR_CMD="${STEP_ROOT}/ofcir/acquire/ofcir-acquire-commands.sh"

  if [[ ! -f "${OFCIR_CMD}" ]]; then
    echo "ofcir-acquire script missing at ${OFCIR_CMD}" >&2
    exit 1
  fi

  exec bash "${OFCIR_CMD}"
else
  # Running locally - create ofcir-compatible interface
  echo "[host-contract] Running in local mode - creating ofcir-compatible interface"

  HOST_IP="${SSH_HOST:-localhost}"
  HOST_SSH_PORT="${SSH_PORT:-22}"

  echo "[host-contract] Target host: ${HOST_IP}:${HOST_SSH_PORT}"

  # Create ofcir-compatible files that assisted-ofcir-setup expects
  echo "${HOST_IP}" > "${SHARED_DIR}/server-ip"

  if [[ "${HOST_SSH_PORT}" != "22" ]]; then
    echo "${HOST_SSH_PORT}" > "${SHARED_DIR}/server-sshport"
  fi

  cat > "${SHARED_DIR}/cir" <<EOF
{
  "name": "local-host-${BUILD_ID:-local}",
  "status": "in use",
  "ip": "${HOST_IP}",
  "extra": {
    "ofcir_port_ssh": ${HOST_SSH_PORT}
  }
}
EOF

  cat > "${SHARED_DIR}/packet-conf.sh" <<'EOF_SCRIPT'
IP=$(cat "${SHARED_DIR}/server-ip")
PORT=22
if [[ -f "${SHARED_DIR}/server-sshport" ]]; then
    PORT=$(<"${SHARED_DIR}/server-sshport")
fi

SSH_KEY_FILE="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
SSHOPTS=( -o Port=$PORT -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR -i "${SSH_KEY_FILE}")
EOF_SCRIPT

  cat >"${ARTIFACT_DIR}/junit_metal_setup.xml" <<EOF
  <testsuite name="metal infra" tests="1" failures="0">
    <testcase name="[sig-metal] should get working host from infra provider"/>
  </testsuite>
EOF

  echo "[host-contract] Created ofcir-compatible interface for local host"
fi
