#!/bin/bash

set -o nounset
set -o pipefail

echo "************ netris-lab gather ************"

if [[ ! -f "${SHARED_DIR}/ssh_config" ]]; then
    echo "No ssh_config found, skipping gather"
    exit 0
fi

ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - << 'EOF' || true
set -o pipefail

cd /opt/netris-test-infra 2>/dev/null && make gather-lab || true
EOF

echo "Copying artifacts from remote machine..."
timeout -s 9 5m scp -r -F "${SHARED_DIR}/ssh_config" \
    "ci_machine:/opt/netris-test-infra/logs/lab/" "${ARTIFACT_DIR}/" 2>&1 || true

echo "netris-lab gather step finished"
