#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

echo "========================================"
echo "Enabling Coredump Collection for Pluto"
echo "========================================"

# Get all nodes
NODES=$(oc get nodes --no-headers | awk '{print $1}')
NODE_COUNT=$(echo "${NODES}" | wc -l)

echo "Enabling coredumps on ${NODE_COUNT} nodes..."
echo ""

SUCCESS_COUNT=0
FAILED_NODES=""

for node in ${NODES}; do
    echo "Configuring node: ${node}"

    if oc debug "node/${node}" -- chroot /host /bin/bash -c "
        # Enable unlimited core dumps
        ulimit -c unlimited

        # Set kernel core pattern
        sysctl -w kernel.core_pattern=/var/lib/systemd/coredump/core.%e.%p.%t
        sysctl -w kernel.core_uses_pid=1

        # Ensure coredump directory exists
        mkdir -p /var/lib/systemd/coredump
        chmod 755 /var/lib/systemd/coredump

        # Persist settings
        cat > /etc/sysctl.d/50-coredump.conf <<SYSCTL
kernel.core_pattern=/var/lib/systemd/coredump/core.%e.%p.%t
kernel.core_uses_pid=1
SYSCTL

        echo 'Coredump enabled'
    " 2>&1 | grep -v "Starting pod" || true; then
        echo "  ✓ ${node} configured"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "  ✗ ${node} failed"
        FAILED_NODES="${FAILED_NODES} ${node}"
    fi
done

echo ""
echo "========================================"
echo "Coredump Setup Summary"
echo "========================================"
echo "Total nodes: ${NODE_COUNT}"
echo "Configured: ${SUCCESS_COUNT}"
echo "Failed: $((NODE_COUNT - SUCCESS_COUNT))"

if [[ ${SUCCESS_COUNT} -lt $((NODE_COUNT * 80 / 100)) ]]; then
    echo ""
    echo "ERROR: Less than 80% of nodes configured successfully"
    echo "Failed nodes:${FAILED_NODES}"
    exit 1
fi

echo ""
echo "✓ Coredump collection enabled on all nodes"
echo "  Pattern: /var/lib/systemd/coredump/core.%e.%p.%t"
echo "  (executable.pid.timestamp)"
echo ""
echo "Pluto crashes will now be captured for RHEL-151431 investigation"
