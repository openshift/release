#!/bin/bash
set -xeuo pipefail

echo "INFO - Starting X25519MLKEM768 TLS1.3 group verification"

# Install oc CLI and required tools
echo "INFO - Installing oc CLI and dependencies..."
curl -sLO "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz"
tar -xzf openshift-client-linux.tar.gz -C /usr/local/bin/ oc
chmod +x /usr/local/bin/oc
rm -f openshift-client-linux.tar.gz

# Verify OpenSSL version
echo "INFO - OpenSSL version:"
openssl version

# Load proxy config if exists
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Expected TLS group
EXPECTED_GROUP="X25519MLKEM768"
TEST_FAILED=0

# Function to test TLS group for a component
test_component_tls() {
    local component_name=$1
    local namespace=$2
    local port=$3
    local label_selector=$4

    echo "INFO - Testing ${component_name} in namespace ${namespace} on port ${port}"

    # Get the first pod matching the label
    POD=$(oc get pods -n "${namespace}" -l "${label_selector}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "$POD" ]]; then
        echo "ERROR - No ${component_name} pod found in namespace ${namespace}"
        return 1
    fi

    echo "INFO - Found pod: ${POD}"

    # Start port-forward in background
    oc port-forward -n "${namespace}" "pod/${POD}" "${port}:${port}" &
    PF_PID=$!

    # Give port-forward time to establish
    echo "INFO - Waiting for port-forward connection to ${component_name}..."
    sleep 5

    # Verify port-forward is working
    local retry=0
    local max_retries=30
    while [[ $retry -lt $max_retries ]]; do
        if netstat -tuln 2>/dev/null | grep -q ":${port} " || \
           ss -tuln 2>/dev/null | grep -q ":${port} " || \
           lsof -i ":${port}" 2>/dev/null | grep -q LISTEN; then
            echo "INFO - Port-forward established on port ${port}"
            break
        fi
        sleep 1
        ((retry++))
    done

    if [[ $retry -eq $max_retries ]]; then
        echo "ERROR - Timeout waiting for port-forward to ${component_name}"
        kill ${PF_PID} 2>/dev/null || true
        return 1
    fi

    # Additional stabilization time
    sleep 2

    # Test TLS handshake and capture negotiated group
    echo "INFO - Testing TLS handshake for ${component_name}..."

    # Run openssl s_client and capture output
    TLS_OUTPUT=$(echo 'Q' | timeout 10 openssl s_client -connect "127.0.0.1:${port}" -servername localhost 2>&1 || true)

    # Save full output for debugging
    echo "DEBUG - Full TLS output for ${component_name}:"
    echo "${TLS_OUTPUT}"

    # Look for the negotiated group in the output
    NEGOTIATED_GROUP=$(echo "${TLS_OUTPUT}" | grep -i "Server Temp Key" || echo "")

    # Alternative: check for group in different format
    if [[ -z "$NEGOTIATED_GROUP" ]]; then
        NEGOTIATED_GROUP=$(echo "${TLS_OUTPUT}" | grep -iE "group.*x25519|mlkem" || echo "")
    fi

    # Clean up port-forward
    kill ${PF_PID} 2>/dev/null || true
    wait ${PF_PID} 2>/dev/null || true

    echo "INFO - Negotiated group info for ${component_name}: ${NEGOTIATED_GROUP}"

    # Verify the expected group
    if echo "${NEGOTIATED_GROUP}" | grep -iq "${EXPECTED_GROUP}"; then
        echo "SUCCESS - ${component_name} negotiated ${EXPECTED_GROUP} TLS1.3 group"
        return 0
    elif echo "${TLS_OUTPUT}" | grep -iq "${EXPECTED_GROUP}"; then
        echo "SUCCESS - ${component_name} negotiated ${EXPECTED_GROUP} TLS1.3 group (found in full output)"
        return 0
    else
        echo "FAILURE - ${component_name} did not negotiate ${EXPECTED_GROUP}"
        echo "INFO - Searched for: ${EXPECTED_GROUP}"
        echo "INFO - Full TLS output available above"
        return 1
    fi
}

# Ensure cluster is stable before testing
echo "INFO - Ensuring cluster is stable before TLS verification"
oc adm wait-for-stable-cluster --minimum-stable-period=30s --timeout=5m

# Test kube-apiserver (port 6443)
echo "========================================="
echo "Testing kube-apiserver"
echo "========================================="
if ! test_component_tls "kube-apiserver" "openshift-kube-apiserver" "6443" "app=openshift-kube-apiserver"; then
    echo "ERROR - kube-apiserver TLS verification failed"
    TEST_FAILED=1
fi

# Test etcd (port 2379)
echo "========================================="
echo "Testing etcd"
echo "========================================="
if ! test_component_tls "etcd" "openshift-etcd" "2379" "app=etcd"; then
    echo "ERROR - etcd TLS verification failed"
    TEST_FAILED=1
fi

# Test kube-scheduler (port 10259)
echo "========================================="
echo "Testing kube-scheduler"
echo "========================================="
if ! test_component_tls "kube-scheduler" "openshift-kube-scheduler" "10259" "app=openshift-kube-scheduler"; then
    echo "ERROR - kube-scheduler TLS verification failed"
    TEST_FAILED=1
fi

# Test kube-controller-manager (port 10257)
echo "========================================="
echo "Testing kube-controller-manager"
echo "========================================="
if ! test_component_tls "kube-controller-manager" "openshift-kube-controller-manager" "10257" "app=kube-controller-manager"; then
    echo "ERROR - kube-controller-manager TLS verification failed"
    TEST_FAILED=1
fi

echo "========================================="
echo "Test Summary"
echo "========================================="

if [[ $TEST_FAILED -eq 1 ]]; then
    echo "FAILURE - One or more components failed X25519MLKEM768 verification"
    exit 1
fi

echo "SUCCESS - All tested control plane components negotiated ${EXPECTED_GROUP} TLS1.3 group"
exit 0
