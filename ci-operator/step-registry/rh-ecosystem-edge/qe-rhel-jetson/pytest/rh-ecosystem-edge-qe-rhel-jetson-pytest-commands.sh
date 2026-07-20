#!/bin/bash
set -euo pipefail

cat /var/run/secrets/jetson-ssh-key/id_rsa > /tmp/jetson_id_rsa
echo "" >> /tmp/jetson_id_rsa
chmod 600 /tmp/jetson_id_rsa

echo "=== Connectivity check ==="
python3 -c "
import socket, sys
host = '${JETSON_HOSTNAME}'
port = 22
s = socket.socket()
s.settimeout(10)
r = s.connect_ex((host, port))
s.close()
print('port 22 OPEN' if r == 0 else f'port 22 UNREACHABLE (errno={r})')
sys.exit(0 if r == 0 else 1)
"

WORK_DIR=$(mktemp -d /tmp/workspace.XXXXXX)
cp -r /workspace/. "${WORK_DIR}/"
cd "${WORK_DIR}"

JETSON_HOST="${JETSON_HOSTNAME}" \
JETSON_USERNAME="root" \
JETSON_KEY_PATH="/tmp/jetson_id_rsa" \
pytest "${TEST_SUITE}" -v
