#!/bin/bash

set -o nounset
set -o pipefail

echo "************ netris-lab cleanup-dns ************"

if [[ ! -f "${SHARED_DIR}/ssh_config" ]]; then
    echo "No ssh_config found, skipping DNS cleanup"
    exit 0
fi

ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - << 'EOF' || true
set -o pipefail

cd /opt/netris-test-infra 2>/dev/null && make cleanup-dns || true
EOF

echo "netris-lab cleanup-dns step finished"
