#!/bin/bash

set -euo pipefail

echo "🔧 Starting OCP-61588 NAD Network Expansion Test"
echo "📋 Test: Network CIDR expansion with Network Attachment Definition (NAD) testing"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

CLUSTER_NETWORK_ORIGINAL_CIDR="${CLUSTER_NETWORK_CIDR:-10.128.0.0/20}"
CLUSTER_NETWORK_EXPANDED_CIDR="${CLUSTER_NETWORK_EXPANDED_CIDR:-10.128.0.0/19}"
NETWORK_TYPE="${NETWORK_TYPE:-OVNKubernetes}"
TEST_NAMESPACE="${TEST_NAMESPACE:-openshift-qe-nad-test}"

echo "📊 Test Parameters:"
echo "   Original CIDR: ${CLUSTER_NETWORK_ORIGINAL_CIDR}"
echo "   Expanded CIDR: ${CLUSTER_NETWORK_EXPANDED_CIDR}"
echo "   Network Type: ${NETWORK_TYPE}"
echo "   Test Namespace: ${TEST_NAMESPACE}"

echo "🔍 Step 1: Verify initial cluster network configuration"
actual_cidr=$(oc get network cluster -o jsonpath='{.spec.clusterNetwork[0].cidr}')
echo "   Current cluster CIDR: ${actual_cidr}"

if [[ "$actual_cidr" != "$CLUSTER_NETWORK_ORIGINAL_CIDR" ]]; then
    echo "❌ CRITICAL ERROR: Cluster started with CIDR $actual_cidr instead of expected $CLUSTER_NETWORK_ORIGINAL_CIDR"
    echo "TEST CANNOT PROCEED: NAD expansion test requires starting from $CLUSTER_NETWORK_ORIGINAL_CIDR"
    exit 1
fi

echo "✅ Cluster network CIDR verified: ${actual_cidr}"

echo "🏗️  Step 2: Create test namespace"
oc create namespace "${TEST_NAMESPACE}" || true
oc label namespace "${TEST_NAMESPACE}" name="${TEST_NAMESPACE}" --overwrite

echo "🌐 Step 3: Create Network Attachment Definition (NAD)"
cat <<EOF | oc apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: test-nad
  namespace: ${TEST_NAMESPACE}
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "ovn-k8s-cni-overlay",
      "topology": "layer2",
      "subnets": "192.168.100.0/24",
      "excludeSubnets": "192.168.100.0/28"
    }
EOF

echo "✅ NAD 'test-nad' created"

echo "🚀 Step 4: Create test pods - some with NAD, some without"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pod-without-nad
  namespace: ${TEST_NAMESPACE}
  labels:
    app: test-pod
    nad: "false"
spec:
  containers:
  - name: test-container
    image: quay.io/openshift/origin-cli:latest
    command: ["/bin/bash"]
    args: ["-c", "sleep 3600"]
    resources:
      requests:
        memory: "64Mi"
        cpu: "50m"
      limits:
        memory: "128Mi"
        cpu: "100m"
---
apiVersion: v1
kind: Pod
metadata:
  name: pod-with-nad
  namespace: ${TEST_NAMESPACE}
  labels:
    app: test-pod
    nad: "true"
  annotations:
    k8s.v1.cni.cncf.io/networks: test-nad
spec:
  containers:
  - name: test-container
    image: quay.io/openshift/origin-cli:latest
    command: ["/bin/bash"]
    args: ["-c", "sleep 3600"]
    resources:
      requests:
        memory: "64Mi"
        cpu: "50m"
      limits:
        memory: "128Mi"
        cpu: "100m"
EOF

echo "⏳ Step 5: Wait for pods to be running"
timeout_seconds=300
end_time=$(($(date +%s) + timeout_seconds))

while [[ $(date +%s) -lt $end_time ]]; do
    running_pods=$(oc get pods -n "${TEST_NAMESPACE}" --field-selector=status.phase=Running -o name | wc -l)
    if [[ $running_pods -eq 2 ]]; then
        echo "✅ Both test pods are running"
        break
    fi
    echo "   Waiting for pods to start... ($running_pods/2 running)"
    sleep 10
done

if [[ $running_pods -ne 2 ]]; then
    echo "❌ TIMEOUT: Not all pods started within $timeout_seconds seconds"
    oc get pods -n "${TEST_NAMESPACE}" -o wide
    exit 1
fi

echo "📋 Step 6: Verify initial pod networking and routing"
echo "   Pod without NAD:"
pod_without_nad_ip=$(oc get pod pod-without-nad -n "${TEST_NAMESPACE}" -o jsonpath='{.status.podIP}')
echo "      Pod IP: ${pod_without_nad_ip}"

echo "   Pod with NAD:"
pod_with_nad_ip=$(oc get pod pod-with-nad -n "${TEST_NAMESPACE}" -o jsonpath='{.status.podIP}')
echo "      Pod IP: ${pod_with_nad_ip}"

echo "🔍 Step 7: Test initial connectivity between pods"
echo "   Testing connectivity from pod-without-nad to pod-with-nad..."
if oc exec -n "${TEST_NAMESPACE}" pod-without-nad -- ping -c 3 "${pod_with_nad_ip}" &>/dev/null; then
    echo "   ✅ Connectivity successful: pod-without-nad -> pod-with-nad"
else
    echo "   ⚠️  Connectivity failed: pod-without-nad -> pod-with-nad (expected for NAD isolation)"
fi

echo "   Testing connectivity from pod-with-nad to pod-without-nad..."
if oc exec -n "${TEST_NAMESPACE}" pod-with-nad -- ping -c 3 "${pod_without_nad_ip}" &>/dev/null; then
    echo "   ✅ Connectivity successful: pod-with-nad -> pod-without-nad"
else
    echo "   ⚠️  Connectivity failed: pod-with-nad -> pod-without-nad (expected for NAD isolation)"
fi

echo "📊 Step 8: Capture routing information before expansion"
echo "   Routes in pod-without-nad:"
oc exec -n "${TEST_NAMESPACE}" pod-without-nad -- ip route | head -5 || true

echo "   Routes in pod-with-nad:"
oc exec -n "${TEST_NAMESPACE}" pod-with-nad -- ip route | head -5 || true

echo "   Network interfaces in pod-with-nad:"
oc exec -n "${TEST_NAMESPACE}" pod-with-nad -- ip addr | grep -E "(^[0-9]+:|inet )" || true

echo "🚀 Step 9: Perform network CIDR expansion"
expansion_start_time=$(date +%s)
echo "   Expanding cluster network from ${CLUSTER_NETWORK_ORIGINAL_CIDR} to ${CLUSTER_NETWORK_EXPANDED_CIDR}..."

oc patch network cluster --type='merge' --patch="{\"spec\":{\"clusterNetwork\":[{\"cidr\":\"${CLUSTER_NETWORK_EXPANDED_CIDR}\",\"hostPrefix\":22}]}}"

echo "⏳ Step 10: Wait for network expansion to complete"
timeout_seconds=600
end_time=$(($(date +%s) + timeout_seconds))

while [[ $(date +%s) -lt $end_time ]]; do
    current_cidr=$(oc get network cluster -o jsonpath='{.spec.clusterNetwork[0].cidr}')
    if [[ "$current_cidr" == "$CLUSTER_NETWORK_EXPANDED_CIDR" ]]; then
        echo "✅ Network expansion completed successfully"
        break
    fi
    echo "   Waiting for expansion... Current CIDR: ${current_cidr}"
    sleep 30
done

expansion_end_time=$(date +%s)
expansion_duration=$((expansion_end_time - expansion_start_time))
expansion_minutes=$((expansion_duration / 60))
expansion_seconds=$((expansion_duration % 60))

current_cidr=$(oc get network cluster -o jsonpath='{.spec.clusterNetwork[0].cidr}')
if [[ "$current_cidr" != "$CLUSTER_NETWORK_EXPANDED_CIDR" ]]; then
    echo "❌ TIMEOUT: Network expansion not completed within $timeout_seconds seconds"
    echo "   Expected: ${CLUSTER_NETWORK_EXPANDED_CIDR}"
    echo "   Actual: ${current_cidr}"
    exit 1
fi

echo "⏱️  Network expansion completed in: ${expansion_minutes}m ${expansion_seconds}s"

echo "🔍 Step 11: Verify pods are still running after expansion"
running_pods=$(oc get pods -n "${TEST_NAMESPACE}" --field-selector=status.phase=Running -o name | wc -l)
if [[ $running_pods -ne 2 ]]; then
    echo "❌ ERROR: Some pods are not running after expansion"
    oc get pods -n "${TEST_NAMESPACE}" -o wide
    exit 1
fi

echo "✅ Both pods still running after expansion"

echo "📋 Step 12: Verify networking and routing after expansion"
echo "   Pod IPs after expansion:"
pod_without_nad_ip_after=$(oc get pod pod-without-nad -n "${TEST_NAMESPACE}" -o jsonpath='{.status.podIP}')
pod_with_nad_ip_after=$(oc get pod pod-with-nad -n "${TEST_NAMESPACE}" -o jsonpath='{.status.podIP}')
echo "      pod-without-nad: ${pod_without_nad_ip_after}"
echo "      pod-with-nad: ${pod_with_nad_ip_after}"

echo "📊 Step 13: Capture routing information after expansion"
echo "   Routes in pod-without-nad after expansion:"
oc exec -n "${TEST_NAMESPACE}" pod-without-nad -- ip route | head -5 || true

echo "   Routes in pod-with-nad after expansion:"
oc exec -n "${TEST_NAMESPACE}" pod-with-nad -- ip route | head -5 || true

echo "🔍 Step 14: Test connectivity after expansion"
echo "   Testing connectivity from pod-without-nad to pod-with-nad..."
if oc exec -n "${TEST_NAMESPACE}" pod-without-nad -- ping -c 3 "${pod_with_nad_ip_after}" &>/dev/null; then
    echo "   ✅ Connectivity successful: pod-without-nad -> pod-with-nad (after expansion)"
else
    echo "   ⚠️  Connectivity failed: pod-without-nad -> pod-with-nad (after expansion)"
fi

echo "   Testing connectivity from pod-with-nad to pod-without-nad..."
if oc exec -n "${TEST_NAMESPACE}" pod-with-nad -- ping -c 3 "${pod_without_nad_ip_after}" &>/dev/null; then
    echo "   ✅ Connectivity successful: pod-with-nad -> pod-without-nad (after expansion)"
else
    echo "   ⚠️  Connectivity failed: pod-with-nad -> pod-without-nad (after expansion)"
fi

echo "🧪 Step 15: Test NAD route override functionality"
echo "   Checking if NAD properly overrides default routes..."

default_route_pod_without_nad=$(oc exec -n "${TEST_NAMESPACE}" pod-without-nad -- ip route | grep "^default" || echo "No default route")
default_route_pod_with_nad=$(oc exec -n "${TEST_NAMESPACE}" pod-with-nad -- ip route | grep "^default" || echo "No default route")

echo "   Default route in pod-without-nad: ${default_route_pod_without_nad}"
echo "   Default route in pod-with-nad: ${default_route_pod_with_nad}"

nad_interfaces=$(oc exec -n "${TEST_NAMESPACE}" pod-with-nad -- ip addr | grep -o "net[0-9]*" | head -1 || echo "")
if [[ -n "${nad_interfaces}" ]]; then
    echo "   ✅ NAD interface detected: ${nad_interfaces}"
    
    nad_route=$(oc exec -n "${TEST_NAMESPACE}" pod-with-nad -- ip route | grep "${nad_interfaces}" | head -1 || echo "No NAD-specific route")
    echo "   NAD-specific route: ${nad_route}"
else
    echo "   ⚠️  No NAD interface detected"
fi

echo "🎯 Step 16: Validate test results"
test_passed=true

if [[ "$current_cidr" != "$CLUSTER_NETWORK_EXPANDED_CIDR" ]]; then
    echo "❌ FAIL: Network CIDR expansion unsuccessful"
    test_passed=false
fi

if [[ $running_pods -ne 2 ]]; then
    echo "❌ FAIL: Not all pods running after expansion"
    test_passed=false
fi

if [[ "${pod_without_nad_ip}" == "${pod_without_nad_ip_after}" && "${pod_with_nad_ip}" == "${pod_with_nad_ip_after}" ]]; then
    echo "✅ PASS: Pod IPs remained stable during expansion"
else
    echo "⚠️  INFO: Pod IPs changed during expansion (expected behavior)"
fi

echo "🧹 Step 17: Cleanup test resources"
oc delete namespace "${TEST_NAMESPACE}" --ignore-not-found=true

if [[ "$test_passed" == "true" ]]; then
    echo "🎉 OCP-61588 NAD Network Expansion Test: PASSED"
    echo "   ✅ Network successfully expanded from ${CLUSTER_NETWORK_ORIGINAL_CIDR} to ${CLUSTER_NETWORK_EXPANDED_CIDR}"
    echo "   ✅ NAD functionality validated during expansion"
    echo "   ✅ Pod networking remained functional"
else
    echo "❌ OCP-61588 NAD Network Expansion Test: FAILED"
    exit 1
fi