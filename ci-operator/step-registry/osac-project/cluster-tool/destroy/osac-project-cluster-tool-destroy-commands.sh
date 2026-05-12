#!/bin/bash

set -o nounset
set -o pipefail

echo "************ cluster-tool destroy ************"

CLONE_NAME="ci-test"

timeout -s 9 5m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s "${CLONE_NAME}" <<'REMOTE_EOF' || true
set -o pipefail
CLONE="$1"

if command -v cluster-tool &>/dev/null || [[ -f /usr/local/bin/cluster-tool ]]; then
    echo "Destroying clone ${CLONE}..."
    python3 /usr/local/bin/cluster-tool destroy "${CLONE}" 2>&1 || true
else
    echo "cluster-tool not found, skipping cleanup"
fi
REMOTE_EOF

echo "Destroy step finished."
