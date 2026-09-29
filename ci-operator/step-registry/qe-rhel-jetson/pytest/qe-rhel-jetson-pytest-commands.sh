#!/bin/bash
set -euo pipefail

SSH_KEY=$(mktemp)
cat /var/run/secrets/jetson-ssh-key/id_rsa > "${SSH_KEY}"
echo "" >> "${SSH_KEY}"
chmod 600 "${SSH_KEY}"

EFFECTIVE_HOST="${JETSON_HOSTNAME}"
EFFECTIVE_PORT=22

# If a jumphost is configured, open a local SSH tunnel through it
if [[ -n "${JUMPHOST:-}" ]]; then
    LOCAL_PORT=2222
    echo "=== Setting up SSH tunnel via jumphost ${JUMPHOST} ==="
    ssh -o StrictHostKeyChecking=accept-new \
        -o ExitOnForwardFailure=yes \
        -i ${SSH_KEY} \
        -N -L "${LOCAL_PORT}:${JETSON_HOSTNAME}:22" \
        "${JUMPHOST}" &
    TUNNEL_PID=$!
    trap 'kill ${TUNNEL_PID} 2>/dev/null || true' EXIT
    # Wait for tunnel to be ready
    for _ in $(seq 1 15); do
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=2 \
               -i ${SSH_KEY} \
               -p "${LOCAL_PORT}" root@127.0.0.1 true 2>/dev/null; then
            break
        fi
        sleep 2
    done
    EFFECTIVE_HOST=127.0.0.1
    EFFECTIVE_PORT="${LOCAL_PORT}"
    echo "=== Tunnel ready: localhost:${LOCAL_PORT} -> ${JETSON_HOSTNAME}:22 ==="
fi

echo "=== Connectivity check ==="
python3 -c "
import socket, sys
host = '${EFFECTIVE_HOST}'
port = ${EFFECTIVE_PORT}
s = socket.socket()
s.settimeout(10)
r = s.connect_ex((host, port))
s.close()
print('port', port, 'OPEN' if r == 0 else f'UNREACHABLE (errno={r})')
sys.exit(0 if r == 0 else 1)
"

WORK_DIR=$(mktemp -d /tmp/workspace.XXXXXX)
cp -r /workspace/. "${WORK_DIR}/"
cd "${WORK_DIR}"

# Configure pytest parallelism via pytest-xdist
# JETSON_PYTEST_WORKERS: 0 or 1 = serial, 2+ = parallel workers
PYTEST_ARGS="-v --junit-xml=${ARTIFACT_DIR}/junit.xml"
if [[ "${JETSON_PYTEST_WORKERS:-0}" -gt 1 ]]; then
    echo "=== Enabling parallel execution with ${JETSON_PYTEST_WORKERS} workers ==="
    PYTEST_ARGS="-n ${JETSON_PYTEST_WORKERS} ${PYTEST_ARGS}"
else
    echo "=== Running tests serially (JETSON_PYTEST_WORKERS=${JETSON_PYTEST_WORKERS:-0}) ==="
fi

JETSON_HOST="${EFFECTIVE_HOST}" \
JETSON_PORT="${EFFECTIVE_PORT}" \
JETSON_USERNAME="root" \
JETSON_KEY_PATH="${SSH_KEY}" \
RUN_SC7_WRAPPER="${RUN_SC7_WRAPPER:-0}" \
pytest ${TEST_SUITE} ${PYTEST_ARGS}

# Collect device logs archives for Prow artifact upload
echo "=== Collecting device log artifacts ==="
if [[ -d "${WORK_DIR}/device_logs" ]]; then
    echo "Found device logs directory"
    mkdir -p "${ARTIFACT_DIR}/device_logs"

    # Copy all tar.gz archives
    LOGS_COPIED=0
    for LOG_ARCHIVE in "${WORK_DIR}/device_logs"/*.tar.gz; do
        if [[ -f "${LOG_ARCHIVE}" ]]; then
            cp -v "${LOG_ARCHIVE}" "${ARTIFACT_DIR}/device_logs/"
            LOGS_COPIED=$((LOGS_COPIED + 1))
        fi
    done

    if [[ ${LOGS_COPIED} -gt 0 ]]; then
        echo "Copied ${LOGS_COPIED} device log archive(s) to artifacts"
        ls -lh "${ARTIFACT_DIR}/device_logs/"
    else
        echo "No .tar.gz files found in device_logs directory"
    fi
else
    echo "No device_logs directory found (tests may not have generated logs)"
fi
