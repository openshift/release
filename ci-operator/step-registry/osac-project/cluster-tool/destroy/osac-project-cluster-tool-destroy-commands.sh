#!/bin/bash

set -o nounset
set -o pipefail

echo "************ cluster-tool destroy ************"

timeout -s 9 5m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s "${CLUSTER_TOOL_FLAVOR_NAME}" <<'REMOTE_EOF' || true
set -o pipefail
CLONE="$1"

if command -v cluster-tool &>/dev/null || [[ -f /usr/local/bin/cluster-tool ]]; then
    echo "Destroying clone ${CLONE}..."
    python3 /usr/local/bin/cluster-tool destroy "${CLONE}" 2>&1 || true
else
    echo "cluster-tool not found, skipping cleanup"
fi

# Clean up CaaS agent VM if it exists (created by caas-agents step)
if virsh dominfo agent-worker-01 &>/dev/null; then
    echo "Cleaning up CaaS agent VM..."
    virsh destroy agent-worker-01 2>/dev/null || true
    virsh undefine agent-worker-01 2>/dev/null || true
    rm -f /data/osac-storage/agent-worker-01.qcow2 /data/osac-storage/discovery.iso
fi
REMOTE_EOF

echo "Destroy step finished."
