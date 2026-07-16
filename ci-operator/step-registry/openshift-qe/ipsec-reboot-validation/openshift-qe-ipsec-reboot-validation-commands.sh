#!/bin/bash
set +e
set -o nounset
set -o pipefail
set -x

echo "====================================="
echo "IPsec Reboot Validation - OCPBUGS-86429"
echo "====================================="

NODE_COUNT=$(oc get nodes --no-headers | wc -l)
WORKER_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)
echo "Total nodes: ${NODE_COUNT}"
echo "Worker nodes: ${WORKER_COUNT}"

# Step 1: Check libreswan version
echo ""
echo "Step 1: Checking libreswan version..."

WORKER_NODE=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk 'NR==1{print $1}')

echo "Checking libreswan on host (${WORKER_NODE})..."
HOST_VERSION=$(oc debug "node/${WORKER_NODE}" -- chroot /host rpm -q libreswan 2>/dev/null | grep -v "Starting pod" || echo "unknown")
echo "Host libreswan: ${HOST_VERSION}"

echo "Checking libreswan in ovn-ipsec container..."
IPSEC_POD=$(oc get pods -n openshift-ovn-kubernetes -l app=ovn-ipsec-host --no-headers | awk 'NR==1{print $1}')
CONTAINER_VERSION=$(oc exec -n openshift-ovn-kubernetes "${IPSEC_POD}" -- rpm -q libreswan 2>/dev/null || echo "unknown")
echo "Container libreswan: ${CONTAINER_VERSION}"

if echo "${HOST_VERSION}" | grep -q "5\.3"; then
    echo "✓ Host has libreswan 5.3"
else
    echo "⚠ Host libreswan is NOT 5.3: ${HOST_VERSION}"
fi

if echo "${CONTAINER_VERSION}" | grep -q "5\.3"; then
    echo "✓ Container has libreswan 5.3"
else
    echo "⚠ Container libreswan is NOT 5.3: ${CONTAINER_VERSION}"
fi

# Step 2: Check IPsec mode
echo ""
echo "Step 2: Verifying IPsec is enabled..."
IPSEC_MODE=$(oc get network.config.openshift.io/cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.ipsecConfig.mode}' 2>/dev/null || echo "unknown")
echo "IPsec mode: ${IPSEC_MODE}"

# Step 3: Count IPsec tunnels
echo ""
echo "Step 3: Counting IPsec tunnels..."

TUNNEL_INFO=$(oc debug "node/${WORKER_NODE}" -- chroot /host ipsec status 2>/dev/null | grep "Total IPsec" || echo "No tunnel info")
echo "Tunnel status: ${TUNNEL_INFO}"

# Check ipsec showstates for ESTABLISHED_CHILD_SA (new 5.x format)
echo ""
echo "Checking IPsec state names (5.x compatibility)..."
STATES=$(oc debug "node/${WORKER_NODE}" -- chroot /host ipsec showstates 2>/dev/null | grep -c "ESTABLISHED_CHILD_SA" || true)
echo "ESTABLISHED_CHILD_SA count on ${WORKER_NODE}: ${STATES}"

# Step 4: Check ovn-ipsec pods
echo ""
echo "Step 4: Checking ovn-ipsec-host pods..."
IPSEC_PODS_RUNNING=$(oc get pods -n openshift-ovn-kubernetes -l app=ovn-ipsec-host --no-headers | grep -c Running || true)
IPSEC_PODS_TOTAL=$(oc get pods -n openshift-ovn-kubernetes -l app=ovn-ipsec-host --no-headers | wc -l)
echo "ovn-ipsec-host pods: ${IPSEC_PODS_RUNNING}/${IPSEC_PODS_TOTAL} running"

if [[ ${IPSEC_PODS_RUNNING} -lt ${IPSEC_PODS_TOTAL} ]]; then
    echo "⚠ Not all ovn-ipsec-host pods are Running"
    oc get pods -n openshift-ovn-kubernetes -l app=ovn-ipsec-host --no-headers | grep -v Running || true
fi

# Step 5: Check for pluto crashes
echo ""
echo "Step 5: Checking for pluto crashes on all nodes..."

CRASH_COUNT=0
CRASH_NODES=""

for node in $(oc get nodes --no-headers | awk '{print $1}'); do
    SEGFAULTS=$(oc debug "node/${node}" -- chroot /host journalctl -k --no-pager 2>/dev/null | grep -c "pluto.*segfault" || true)
    if [[ ${SEGFAULTS} -gt 0 ]]; then
        echo "  ⚠ ${node}: ${SEGFAULTS} pluto segfault(s)"
        CRASH_COUNT=$((CRASH_COUNT + 1))
        CRASH_NODES="${CRASH_NODES} ${node}"
    fi
done

echo "Nodes with pluto crashes: ${CRASH_COUNT}/${NODE_COUNT}"

if [[ ${CRASH_COUNT} -gt 0 ]]; then
    echo "Crashed nodes:${CRASH_NODES}"
    echo ""
    echo "Checking for coredumps on crashed nodes..."
    for node in ${CRASH_NODES}; do
        COREDUMPS=$(oc debug "node/${node}" -- chroot /host ls -1 /var/lib/systemd/coredump/core.pluto.* 2>/dev/null || echo "none")
        echo "  ${node}: ${COREDUMPS}"
    done
fi

# Step 6: Quick connectivity spot-check
echo ""
echo "Step 6: Connectivity spot-check..."

NODE1=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk 'NR==1{print $1}')
NODE2=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk 'NR==2{print $1}')
IP1=$(oc get node "${NODE1}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
IP2=$(oc get node "${NODE2}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

echo "Testing: ${NODE1} (${IP1}) -> ${NODE2} (${IP2})"
PING_RESULT=$(oc debug "node/${NODE1}" -- chroot /host ping -c 3 -W 5 "${IP2}" 2>/dev/null | tail -1 || echo "ping failed")
echo "Result: ${PING_RESULT}"

# Summary
echo ""
echo "====================================="
echo "Validation Summary"
echo "====================================="
echo "Host libreswan: ${HOST_VERSION}"
echo "Container libreswan: ${CONTAINER_VERSION}"
echo "IPsec mode: ${IPSEC_MODE}"
echo "Tunnels: ${TUNNEL_INFO}"
echo "ESTABLISHED_CHILD_SA states: ${STATES}"
echo "ovn-ipsec pods: ${IPSEC_PODS_RUNNING}/${IPSEC_PODS_TOTAL}"
echo "Pluto crashes: ${CRASH_COUNT}/${NODE_COUNT} nodes"
echo "Connectivity: ${PING_RESULT}"
echo "====================================="

exit 0
