#!/bin/bash
set -euo pipefail

: "${SHARED_DIR?must be set}"

# Default to Prow/ofcir behavior unless explicitly running locally
if [[ "${HOST_CONTRACT_LOCAL:-}" != "true" ]]; then
  # Running in Prow - delegate to ofcir-gather
  echo "[host-contract] Running in Prow environment - delegating to ofcir-gather"

  STEP_ROOT=$(realpath "$(dirname "${BASH_SOURCE[0]}")/../../../..")
  OFCIR_CMD="${STEP_ROOT}/ofcir/gather/ofcir-gather-commands.sh"

  if [[ ! -f "${OFCIR_CMD}" ]]; then
    echo "ofcir-gather script missing at ${OFCIR_CMD}" >&2
    exit 1
  fi

  exec bash "${OFCIR_CMD}"
else
  # Running locally - gather local logs if needed
  echo "[host-contract] Running in local mode - gathering local logs"

  # For local execution, there's typically no special gathering needed
  # since logs are already collected by the main execution flow
  echo "[host-contract] Local log gathering completed"
fi
