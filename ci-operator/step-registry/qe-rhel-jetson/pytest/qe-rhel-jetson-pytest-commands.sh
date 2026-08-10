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

JETSON_HOST="${EFFECTIVE_HOST}" \
JETSON_PORT="${EFFECTIVE_PORT}" \
JETSON_USERNAME="root" \
JETSON_KEY_PATH="${SSH_KEY}" \
pytest "${TEST_SUITE}" -v
