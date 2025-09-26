#!/bin/bash
set -euo pipefail

: "${SHARED_DIR?must be set}"

# Default to Prow/ofcir behavior unless explicitly running locally
if [[ "${HOST_CONTRACT_LOCAL:-}" != "true" ]]; then
  # Running in Prow - delegate to ofcir-release
  echo "[host-contract] Running in Prow environment - delegating to ofcir-release"

  STEP_ROOT=$(realpath "$(dirname "${BASH_SOURCE[0]}")/../../../..")
  OFCIR_CMD="${STEP_ROOT}/ofcir/release/ofcir-release-commands.sh"

  if [[ ! -f "${OFCIR_CMD}" ]]; then
    echo "ofcir-release script missing at ${OFCIR_CMD}" >&2
    exit 1
  fi

  exec bash "${OFCIR_CMD}"
else
  # Running locally - clean up local files
  echo "[host-contract] Running in local mode - cleaning up local interface"

  # Clean up the files we created
  rm -f "${SHARED_DIR}/server-ip" || true
  rm -f "${SHARED_DIR}/server-sshport" || true
  rm -f "${SHARED_DIR}/cir" || true
  rm -f "${SHARED_DIR}/packet-conf.sh" || true

  echo "[host-contract] Local cleanup completed"
fi
