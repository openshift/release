#!/bin/bash
set +e
set -o nounset
set -o pipefail
set -x

EVIDENCE="${ARTIFACT_DIR}/ipsec-evidence.txt"

echo "====================================="
echo "IPsec Reboot Validation - OCPBUGS-86429"
echo "====================================="

NODE_COUNT=$(oc get nodes --no-headers | wc -l)
WORKER_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)
echo "Total nodes: ${NODE_COUNT}"
echo "Worker nodes: ${WORKER_COUNT}"

WORKER_NODE=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk 'NR==1{print $1}')

# --- Evidence: cluster snapshot ---
{
    echo "=== IPsec Evidence Collection ==="
    echo "Timestamp: $(date -u)"
    echo "Total nodes: ${NODE_COUNT}"
    echo "Worker nodes: ${WORKER_COUNT}"
    echo ""
    echo "--- Node list ---"
    oc get nodes -o wide --no-headers 2>/dev/null || true
    echo ""
} >> "${EVIDENCE}"

# Detect IPsec pods — label is app=ovn-ipsec (not app=ovn-ipsec-host)
echo ""
echo "Step 0: Detecting IPsec pods..."
IPSEC_POD=""
IPSEC_LABEL=""
for label in "app=ovn-ipsec" "app=ovn-ipsec-host" "name=ovn-ipsec"; do
    COUNT=$(oc get pods -n openshift-ovn-kubernetes -l "${label}" --no-headers 2>/dev/null | grep -c Running || true)
    if [[ ${COUNT} -gt 0 ]]; then
        IPSEC_LABEL="${label}"
        IPSEC_POD=$(oc get pods -n openshift-ovn-kubernetes -l "${label}" --no-headers --field-selector="spec.nodeName=${WORKER_NODE}" 2>/dev/null | awk 'NR==1{print $1}')
        echo "Found ${COUNT} IPsec pods with label ${label}"
        break
    fi
done

if [[ -z "${IPSEC_POD}" ]]; then
    echo "WARNING: No IPsec pod found on ${WORKER_NODE}, trying first available pod"
    if [[ -n "${IPSEC_LABEL}" ]]; then
        IPSEC_POD=$(oc get pods -n openshift-ovn-kubernetes -l "${IPSEC_LABEL}" --no-headers 2>/dev/null | awk 'NR==1{print $1}')
    fi
fi
echo "Using IPsec pod: ${IPSEC_POD:-none}"

# Step 1: Check libreswan version via oc exec (not oc debug — faster, more reliable)
echo ""
echo "Step 1: Checking libreswan version..."

if [[ -n "${IPSEC_POD}" ]]; then
    CONTAINER_VERSION=$(oc exec -n openshift-ovn-kubernetes "${IPSEC_POD}" -c ovn-ipsec -- rpm -q libreswan 2>/dev/null || echo "unknown")
    echo "Container libreswan (ovn-ipsec): ${CONTAINER_VERSION}"
else
    CONTAINER_VERSION="unknown (no pod found)"
    echo "Container libreswan: ${CONTAINER_VERSION}"
fi

echo "Checking libreswan on host (${WORKER_NODE}) via oc debug..."
HOST_VERSION=$(oc debug "node/${WORKER_NODE}" -- chroot /host bash -c "rpm -q libreswan 2>/dev/null" 2>/dev/null | grep -v "^Starting pod\|^Removing debug\|^$" || echo "unknown")
echo "Host libreswan: ${HOST_VERSION}"

if echo "${CONTAINER_VERSION}" | grep -q "libreswan-5\.3"; then
    echo "OK Container has libreswan 5.3"
else
    echo "WARNING Container libreswan is NOT 5.3: ${CONTAINER_VERSION}"
fi

if echo "${HOST_VERSION}" | grep -q "libreswan-5\.3"; then
    echo "OK Host has libreswan 5.3"
else
    echo "WARNING Host libreswan is NOT 5.3: ${HOST_VERSION}"
fi

# --- Evidence: libreswan version ---
{
    echo "--- Libreswan version ---"
    echo "Host: ${HOST_VERSION}"
    echo "Container: ${CONTAINER_VERSION}"
    echo ""
} >> "${EVIDENCE}"

# Step 2: Check IPsec mode (handle implicit Full mode for ipsecConfig: {})
echo ""
echo "Step 2: Verifying IPsec is enabled..."
IPSEC_MODE=$(oc get network.config.openshift.io/cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.ipsecConfig.mode}' 2>/dev/null || true)
if [[ -n "${IPSEC_MODE}" ]]; then
    echo "IPsec mode: ${IPSEC_MODE}"
else
    IPSEC_CONFIG=$(oc get network.config.openshift.io/cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.ipsecConfig}' 2>/dev/null || true)
    if [[ -n "${IPSEC_CONFIG}" ]]; then
        IPSEC_MODE="Full (implicit)"
        echo "IPsec mode: Full (implicit - ipsecConfig present without explicit mode)"
    else
        IPSEC_MODE="Disabled"
        echo "IPsec mode: Disabled (no ipsecConfig)"
    fi
fi

# --- Evidence: IPsec config ---
{
    echo "--- IPsec config ---"
    echo "Mode: ${IPSEC_MODE}"
    echo "Raw ovnKubernetesConfig:"
    oc get network.config.openshift.io/cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig}' 2>/dev/null || true
    echo ""
    echo ""
} >> "${EVIDENCE}"

# Step 3: Count IPsec tunnels via oc exec
echo ""
echo "Step 3: Counting IPsec tunnels..."

if [[ -n "${IPSEC_POD}" ]]; then
    TUNNEL_INFO=$(oc exec -n openshift-ovn-kubernetes "${IPSEC_POD}" -c ovn-ipsec -- ipsec status 2>/dev/null | grep "Total IPsec" || echo "No tunnel info")
    echo "Tunnel status: ${TUNNEL_INFO}"

    EXPECTED_TUNNELS=$((NODE_COUNT - 1))
    TUNNEL_LOG=$(oc logs "${IPSEC_POD}" -n openshift-ovn-kubernetes -c ovn-ipsec --tail=50 2>/dev/null || true)
    if echo "${TUNNEL_LOG}" | grep -q "Connections for all(${EXPECTED_TUNNELS}) configured tunnels are Up"; then
        echo "OK All ${EXPECTED_TUNNELS} tunnels Up (confirmed via pod logs)"
    else
        echo "Tunnel log check: tunnels may still be converging"
    fi

    # --- Evidence: full ipsec status + showstates ---
    {
        echo "--- Full ipsec status (${WORKER_NODE}) ---"
        oc exec -n openshift-ovn-kubernetes "${IPSEC_POD}" -c ovn-ipsec -- ipsec status 2>/dev/null || true
        echo ""
        echo "--- ipsec showstates (first 20 lines) ---"
        oc exec -n openshift-ovn-kubernetes "${IPSEC_POD}" -c ovn-ipsec -- ipsec showstates 2>/dev/null | head -20 || true
        echo ""
    } >> "${EVIDENCE}"
else
    TUNNEL_INFO="No tunnel info (no IPsec pod)"
    echo "Tunnel status: ${TUNNEL_INFO}"
fi

# Step 4: Check ovn-ipsec pods
echo ""
echo "Step 4: Checking IPsec pods..."
if [[ -n "${IPSEC_LABEL}" ]]; then
    IPSEC_PODS_RUNNING=$(oc get pods -n openshift-ovn-kubernetes -l "${IPSEC_LABEL}" --no-headers | grep -c Running || true)
    IPSEC_PODS_TOTAL=$(oc get pods -n openshift-ovn-kubernetes -l "${IPSEC_LABEL}" --no-headers | wc -l)
    echo "IPsec pods (${IPSEC_LABEL}): ${IPSEC_PODS_RUNNING}/${IPSEC_PODS_TOTAL} running"

    if [[ ${IPSEC_PODS_RUNNING} -lt ${IPSEC_PODS_TOTAL} ]]; then
        echo "WARNING Not all IPsec pods are Running"
        oc get pods -n openshift-ovn-kubernetes -l "${IPSEC_LABEL}" --no-headers | grep -v Running || true
    fi

    # --- Evidence: full pod list ---
    {
        echo "--- IPsec pod list (${IPSEC_LABEL}) ---"
        oc get pods -n openshift-ovn-kubernetes -l "${IPSEC_LABEL}" -o wide --no-headers 2>/dev/null || true
        echo ""
    } >> "${EVIDENCE}"
else
    IPSEC_PODS_RUNNING=0
    IPSEC_PODS_TOTAL=0
    echo "IPsec pods: not found (tried app=ovn-ipsec, app=ovn-ipsec-host, name=ovn-ipsec)"
fi

# Step 5: Check for pluto crashes
echo ""
echo "Step 5: Checking for pluto crashes on all nodes..."

CRASH_COUNT=0
CRASH_NODES=""

echo "--- Pluto crash check (all nodes) ---" >> "${EVIDENCE}"
for node in $(oc get nodes --no-headers | awk '{print $1}'); do
    SEGFAULTS=$(oc debug "node/${node}" -- chroot /host journalctl -k --no-pager 2>/dev/null | grep -c "pluto.*segfault" || true)
    echo "${node}: segfaults=${SEGFAULTS}" >> "${EVIDENCE}"
    if [[ ${SEGFAULTS} -gt 0 ]]; then
        echo "  WARNING ${node}: ${SEGFAULTS} pluto segfault(s)"
        CRASH_COUNT=$((CRASH_COUNT + 1))
        CRASH_NODES="${CRASH_NODES} ${node}"
    fi
done

echo "Nodes with pluto crashes: ${CRASH_COUNT}/${NODE_COUNT}"
echo "Pluto crashes: ${CRASH_COUNT}/${NODE_COUNT} nodes" >> "${EVIDENCE}"

if [[ ${CRASH_COUNT} -gt 0 ]]; then
    echo "Crashed nodes:${CRASH_NODES}"
    echo ""
    echo "Checking for coredumps on crashed nodes..."
    for node in ${CRASH_NODES}; do
        COREDUMPS=$(oc debug "node/${node}" -- chroot /host ls -1 /var/lib/systemd/coredump/core.pluto.* 2>/dev/null || echo "none")
        echo "  ${node}: ${COREDUMPS}"
        # --- Evidence: coredumps + pluto journal for crashed nodes ---
        {
            echo "--- ${node} coredumps ---"
            echo "${COREDUMPS}"
            echo "--- ${node} pluto journal (last 50 lines) ---"
            oc debug "node/${node}" -- chroot /host journalctl -u ipsec --no-pager -n 50 2>/dev/null || true
            echo ""
        } >> "${EVIDENCE}"
    done
fi
echo "" >> "${EVIDENCE}"

# Step 6: Connectivity spot-check via oc exec
echo ""
echo "Step 6: Connectivity spot-check..."

NODE1="${WORKER_NODE}"
NODE2=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk 'NR==2{print $1}')
IP2=$(oc get node "${NODE2}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

echo "Testing: ${NODE1} -> ${NODE2} (${IP2})"
if [[ -n "${IPSEC_POD}" ]]; then
    PING_RESULT=$(oc exec -n openshift-ovn-kubernetes "${IPSEC_POD}" -c ovn-ipsec -- ping -c 3 -W 5 "${IP2}" 2>/dev/null | tail -1 || echo "ping failed")
else
    PING_RESULT=$(oc debug "node/${NODE1}" -- chroot /host ping -c 3 -W 5 "${IP2}" 2>/dev/null | tail -1 || echo "ping failed")
fi
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
echo "IPsec pods (${IPSEC_LABEL:-none}): ${IPSEC_PODS_RUNNING}/${IPSEC_PODS_TOTAL}"
echo "Pluto crashes: ${CRASH_COUNT}/${NODE_COUNT} nodes"
echo "Connectivity: ${PING_RESULT}"
echo "====================================="

# --- Evidence: summary ---
{
    echo "=== Validation Summary ==="
    echo "Host libreswan: ${HOST_VERSION}"
    echo "Container libreswan: ${CONTAINER_VERSION}"
    echo "IPsec mode: ${IPSEC_MODE}"
    echo "Tunnels: ${TUNNEL_INFO}"
    echo "IPsec pods (${IPSEC_LABEL:-none}): ${IPSEC_PODS_RUNNING}/${IPSEC_PODS_TOTAL}"
    echo "Pluto crashes: ${CRASH_COUNT}/${NODE_COUNT} nodes"
    echo "Connectivity: ${PING_RESULT}"
} >> "${EVIDENCE}"

exit 0
