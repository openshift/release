#!/bin/bash

set -o nounset
set -o pipefail

echo "************ netris-caas gather ************"

if [[ ! -f "${SHARED_DIR}/ssh_config" ]]; then
    echo "No ssh_config found, skipping gather"
    exit 0
fi

ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - << 'EOF' || true
set -o pipefail

cd /opt/netris-test-infra 2>/dev/null && make gather-caas || true
EOF

echo "Copying artifacts from remote machine..."
timeout -s 9 5m scp -r -F "${SHARED_DIR}/ssh_config" \
    "ci_machine:/opt/netris-test-infra/logs/caas/" "${ARTIFACT_DIR}/" 2>&1 || true

echo "netris-caas gather step finished"
