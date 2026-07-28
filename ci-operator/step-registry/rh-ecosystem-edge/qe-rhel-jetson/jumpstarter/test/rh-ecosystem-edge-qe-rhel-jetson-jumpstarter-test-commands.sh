#!/bin/bash
set -euo pipefail

# Set up Jumpstarter client config from mounted secret
mkdir -p ~/.config/jumpstarter
cp /var/run/secrets/jumpstarter/config ~/.config/jumpstarter/client.yaml

# Load SSH credentials without leaking them into logs
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

export JETSON_USERNAME
JETSON_USERNAME=$(cat /var/run/secrets/jetson-ssh/username)
export JETSON_PASSWORD
JETSON_PASSWORD=$(cat /var/run/secrets/jetson-ssh/password)

$WAS_TRACING && set -x

# Create a lease for the device; prefer explicit device name, fall back to selector
LEASE_ACQUIRE_ARGS=(--duration "${LEASE_DURATION}")
if [[ -n "${JUMPSTARTER_DEVICE_NAME:-}" ]]; then
    LEASE_ACQUIRE_ARGS+=(-n "${JUMPSTARTER_DEVICE_NAME}")
elif [[ -n "${JUMPSTARTER_SELECTOR:-}" ]]; then
    LEASE_ACQUIRE_ARGS+=(-l "${JUMPSTARTER_SELECTOR}")
elif [[ -n "${JUMPSTARTER_LEASE_NAME:-}" ]]; then
    # Backward-compat: caller already holds a lease, skip creation
    LEASE="${JUMPSTARTER_LEASE_NAME}"
fi

if [[ -z "${LEASE:-}" ]]; then
    echo "[jumpstarter-test] Creating lease (duration=${LEASE_DURATION})..."
    LEASE=$(jmp create lease "${LEASE_ACQUIRE_ARGS[@]}" -o name)
    echo "[jumpstarter-test] Lease acquired: ${LEASE}"
    # Release the lease when the step exits (success or failure)
    trap 'echo "[jumpstarter-test] Releasing lease ${LEASE}"; jmp delete lease "${LEASE}"' EXIT
fi

cd /opt/qe-rhel-jetson-jumpstarter
jmp shell --lease "${LEASE}" -- \
    python wrapper.py pytest "${TEST_SUITE}"
