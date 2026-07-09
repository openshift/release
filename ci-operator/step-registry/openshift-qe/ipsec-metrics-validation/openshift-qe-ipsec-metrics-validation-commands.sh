#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

cat /etc/os-release
oc config view
oc projects

echo "====================================="
echo "IPsec Metrics Validation Test Suite"
echo "====================================="

# Check if registry URL is provided via ConfigMap (for testing custom builds)
echo ""
echo "Checking for custom registry URL in ConfigMap..."
if oc get configmap ipsec-registry-config -n ci &>/dev/null; then
    REGISTRY_URL=$(oc get configmap ipsec-registry-config -n ci -o jsonpath='{.data.REGISTRY_URL}' 2>/dev/null || echo "")
    if [[ -n "${REGISTRY_URL}" ]]; then
        echo "✓ Found custom registry URL in ConfigMap: ${REGISTRY_URL}"
        export CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${REGISTRY_URL}"
        echo "  This cluster was built with custom images from Cluster Bot"
    else
        echo "⚠ ConfigMap exists but REGISTRY_URL is empty, using default nightly build"
    fi
else
    echo "ℹ No ConfigMap found, using default nightly build"
fi

# Get cluster info
CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
NODE_COUNT=$(oc get nodes --no-headers | wc -l)
echo "Cluster: ${CLUSTER_NAME}"
echo "Total nodes: ${NODE_COUNT}"

# Enable coredump collection for pluto crashes
echo ""
echo "Enabling coredump collection for libreswan pluto..."
oc debug node/$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | head -1 | awk '{print $1}') -- chroot /host /bin/bash -c "
  # Enable coredumps
  ulimit -c unlimited
  echo 'kernel.core_pattern=/var/lib/systemd/coredump/core.%e.%p.%t' > /etc/sysctl.d/50-coredump.conf
  sysctl -p /etc/sysctl.d/50-coredump.conf

  # Ensure coredump directory exists
  mkdir -p /var/lib/systemd/coredump
  chmod 755 /var/lib/systemd/coredump

  echo 'Coredump collection enabled'
" || echo "Warning: Could not enable coredumps on all nodes"

# Step 1: Verify IPsec is enabled
echo ""
echo "Step 1: Verifying IPsec is enabled..."
IPSEC_ENABLED=$(oc get network.config.openshift.io/cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.ipsecConfig.mode}')
if [[ "${IPSEC_ENABLED}" != "Full" ]]; then
    echo "ERROR: IPsec is not enabled! Expected mode=Full, got: ${IPSEC_ENABLED}"
    exit 1
fi
echo "✓ IPsec mode: ${IPSEC_ENABLED}"

# Step 2: Check ovnkube-controller pods are running
echo ""
echo "Step 2: Checking ovnkube-controller pods..."
OVNKUBE_PODS=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-control-plane --no-headers | grep Running | wc -l)
if [[ ${OVNKUBE_PODS} -lt 1 ]]; then
    echo "ERROR: No running ovnkube-controller pods found!"
    exit 1
fi
echo "✓ Found ${OVNKUBE_PODS} running ovnkube-controller pods"

# Step 3: Verify new IPsec Child SA state metric exists
echo ""
echo "Step 3: Validating new IPsec metric: ovnkube_controller_ipsec_tunnel_ike_child_sa_state..."

# Get Prometheus token (disable tracing to avoid leaking token in logs)
set +x
PROM_TOKEN=$(oc sa get-token prometheus-k8s -n openshift-monitoring)
THANOS_QUERIER_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')

# Query the new metric
METRIC_QUERY='ovnkube_controller_ipsec_tunnel_ike_child_sa_state'
METRIC_RESULT=$(curl -k -H "Authorization: Bearer ${PROM_TOKEN}" \
    "https://${THANOS_QUERIER_HOST}/api/v1/query?query=${METRIC_QUERY}" | \
    jq -r '.data.result | length')
set -x

if [[ ${METRIC_RESULT} -eq 0 ]]; then
    echo "ERROR: Metric ovnkube_controller_ipsec_tunnel_ike_child_sa_state not found!"
    echo "This metric should be exposed by ovn-kubernetes PR #3259"
    exit 1
fi

echo "✓ Metric exists with ${METRIC_RESULT} time series"

# Show sample metric values (disable tracing)
echo ""
echo "Sample metric values:"
set +x
curl -k -H "Authorization: Bearer ${PROM_TOKEN}" \
    "https://${THANOS_QUERIER_HOST}/api/v1/query?query=${METRIC_QUERY}" | \
    jq -r '.data.result[0:5][] | "  Node: \(.metric.node) | Remote IP: \(.metric.remote_ip) | State: \(.value[1])"'
set -x

# Step 4: Check metric labels
echo ""
echo "Step 4: Validating metric labels (node, remote_ip, local_ip)..."
set +x
LABEL_CHECK=$(curl -k -H "Authorization: Bearer ${PROM_TOKEN}" \
    "https://${THANOS_QUERIER_HOST}/api/v1/query?query=${METRIC_QUERY}" | \
    jq -r '.data.result[0].metric | has("node") and has("remote_ip") and has("local_ip")')
set -x

if [[ "${LABEL_CHECK}" != "true" ]]; then
    echo "ERROR: Metric is missing required labels (node, remote_ip, local_ip)"
    exit 1
fi
echo "✓ All required labels present"

# Step 5: Verify Child SA states
echo ""
echo "Step 5: Checking IPsec Child SA tunnel states..."

# State values: 0=Unknown, 1=Installed, 2=Rekeyed, 3=Deleting, 4=Deleted
set +x
INSTALLED_TUNNELS=$(curl -k -H "Authorization: Bearer ${PROM_TOKEN}" \
    "https://${THANOS_QUERIER_HOST}/api/v1/query?query=${METRIC_QUERY}%3D%3D1" | \
    jq -r '.data.result | length')

TOTAL_TUNNELS=$(curl -k -H "Authorization: Bearer ${PROM_TOKEN}" \
    "https://${THANOS_QUERIER_HOST}/api/v1/query?query=${METRIC_QUERY}" | \
    jq -r '.data.result | length')
set -x

echo "Total IPsec tunnels: ${TOTAL_TUNNELS}"
echo "Installed (healthy) tunnels: ${INSTALLED_TUNNELS}"

# Calculate expected tunnels (N*(N-1) for full mesh)
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)
EXPECTED_TUNNELS=$((WORKER_NODES * (WORKER_NODES - 1)))

echo "Worker nodes: ${WORKER_NODES}"
echo "Expected tunnels (N*(N-1)): ${EXPECTED_TUNNELS}"

if [[ ${INSTALLED_TUNNELS} -lt $((EXPECTED_TUNNELS * 90 / 100)) ]]; then
    echo "WARNING: Less than 90% of tunnels are in INSTALLED state!"
    echo "This may indicate IPsec tunnel issues"
fi

# Step 6: Run connectivity tests
echo ""
echo "Step 6: Running N×N connectivity matrix test..."

# Create test namespace
TEST_NS="ipsec-connectivity-test"
oc delete namespace ${TEST_NS} --ignore-not-found=true

# Wait for namespace to be fully deleted to avoid race condition
echo "Waiting for namespace deletion to complete..."
for i in {1..30}; do
    if ! oc get namespace ${TEST_NS} &>/dev/null; then
        break
    fi
    echo "  Waiting for ${TEST_NS} to finish terminating... ($i/30)"
    sleep 2
done

oc create namespace ${TEST_NS}

# Deploy nginx pods on all worker nodes
echo "Deploying nginx pods across all worker nodes..."
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nginx-test
  namespace: ${TEST_NS}
spec:
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      containers:
      - name: nginx
        image: quay.io/redhat-performance/test-nginx:latest
        ports:
        - containerPort: 8080
          protocol: TCP
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
EOF

# Wait for all nginx pods to be ready (increased timeout for 250-node scale)
echo "Waiting for nginx pods to be ready across all nodes..."
echo "This may take 10-15 minutes for image pulls across 250 nodes..."

# Use longer timeout for large-scale deployments (30 minutes)
if ! oc wait --for=condition=ready pod -l app=nginx-test -n ${TEST_NS} --timeout=1800s; then
    echo "WARNING: Not all nginx pods became ready within 30 minutes"
    echo "Checking partial deployment status..."
    oc get pods -n ${TEST_NS} -l app=nginx-test --no-headers

    READY_PODS=$(oc get pods -n ${TEST_NS} -l app=nginx-test --no-headers | grep -c Running || echo "0")
    TOTAL_WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)

    if [[ ${READY_PODS} -lt $((TOTAL_WORKERS * 80 / 100)) ]]; then
        echo "ERROR: Less than 80% of nginx pods are ready (${READY_PODS}/${TOTAL_WORKERS})"
        exit 1
    fi

    echo "Proceeding with partial deployment: ${READY_PODS}/${TOTAL_WORKERS} pods ready"
fi

NGINX_POD_COUNT=$(oc get pods -n ${TEST_NS} -l app=nginx-test --no-headers | grep Running | wc -l)
echo "✓ ${NGINX_POD_COUNT} nginx pods running"

# Run connectivity test
echo ""
echo "Testing pod-to-pod connectivity across all nodes..."

# Get all nginx pod IPs and nodes
oc get pods -n ${TEST_NS} -l app=nginx-test -o json | \
  jq -r '.items[] | "\(.status.podIP) \(.spec.nodeName) \(.metadata.name)"' > /tmp/nginx_pods.txt

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

while IFS= read -r source_line; do
    SOURCE_IP=$(echo ${source_line} | awk '{print $1}')
    SOURCE_NODE=$(echo ${source_line} | awk '{print $2}')
    SOURCE_POD=$(echo ${source_line} | awk '{print $3}')

    while IFS= read -r target_line; do
        TARGET_IP=$(echo ${target_line} | awk '{print $1}')
        TARGET_NODE=$(echo ${target_line} | awk '{print $2}')

        # Skip self-connectivity
        if [[ "${SOURCE_IP}" == "${TARGET_IP}" ]]; then
            continue
        fi

        TOTAL_TESTS=$((TOTAL_TESTS + 1))

        # Test connectivity with timeout
        if oc exec -n ${TEST_NS} ${SOURCE_POD} -- timeout 5 curl -s -o /dev/null -w "%{http_code}" http://${TARGET_IP}:8080 > /tmp/curl_result.txt 2>&1; then
            HTTP_CODE=$(cat /tmp/curl_result.txt)
            if [[ "${HTTP_CODE}" == "200" ]]; then
                PASSED_TESTS=$((PASSED_TESTS + 1))
            else
                echo "  FAIL: ${SOURCE_NODE} → ${TARGET_NODE} (HTTP ${HTTP_CODE})"
                FAILED_TESTS=$((FAILED_TESTS + 1))
            fi
        else
            echo "  FAIL: ${SOURCE_NODE} → ${TARGET_NODE} (timeout/error)"
            FAILED_TESTS=$((FAILED_TESTS + 1))
        fi
    done < /tmp/nginx_pods.txt
done < /tmp/nginx_pods.txt

echo ""
echo "Connectivity Test Results:"
echo "  Total tests: ${TOTAL_TESTS}"
echo "  Passed: ${PASSED_TESTS}"
echo "  Failed: ${FAILED_TESTS}"
echo "  Success rate: $(awk "BEGIN {printf \"%.2f\", (${PASSED_TESTS}/${TOTAL_TESTS})*100}")%"

# Cleanup
oc delete namespace ${TEST_NS} --ignore-not-found=true

# Step 7: Check for pluto crashes and collect coredumps
echo ""
echo "Step 7: Checking for pluto crashes..."

CRASH_COUNT=0
COREDUMP_COLLECTED=0

for node in $(oc get nodes --no-headers | awk '{print $1}'); do
    echo "Checking node: ${node}"

    # Check for pluto segfaults in kernel logs
    SEGFAULTS=$(oc debug node/${node} -- chroot /host journalctl -k --no-pager | grep -c "pluto.*segfault" || echo "0")

    if [[ ${SEGFAULTS} -gt 0 ]]; then
        echo "  ⚠️  Found ${SEGFAULTS} pluto segfault(s) on ${node}"
        CRASH_COUNT=$((CRASH_COUNT + 1))

        # Try to collect coredumps
        COREDUMPS=$(oc debug node/${node} -- chroot /host /bin/bash -c "ls -1 /var/lib/systemd/coredump/core.pluto.* 2>/dev/null || echo ''")

        if [[ -n "${COREDUMPS}" ]]; then
            echo "  ✓ Found coredumps on ${node}:"
            echo "${COREDUMPS}" | while read core; do
                if [[ -n "${core}" ]]; then
                    echo "    - ${core}"
                    COREDUMP_COLLECTED=$((COREDUMP_COLLECTED + 1))
                fi
            done
        else
            echo "  ⚠️  No coredumps found (may need systemd-coredump enabled)"
        fi
    fi
done

echo ""
echo "Crash Summary:"
echo "  Nodes with pluto crashes: ${CRASH_COUNT}/${NODE_COUNT}"
echo "  Coredumps collected: ${COREDUMP_COLLECTED}"

if [[ ${CRASH_COUNT} -gt 0 ]]; then
    echo ""
    echo "⚠️  WARNING: Pluto crashes detected!"
    echo "   This indicates OCPBUGS-55453 / RHEL-151431 libreswan regression"
    echo "   Coredumps location: /var/lib/systemd/coredump/ on affected nodes"
fi

# Step 9: Final validation
echo ""
echo "====================================="
echo "Test Summary"
echo "====================================="

if [[ ${FAILED_TESTS} -gt 0 ]]; then
    echo "❌ FAILED: Connectivity test failed (${FAILED_TESTS} failures)"
    exit 1
fi

if [[ ${INSTALLED_TUNNELS} -lt $((EXPECTED_TUNNELS * 90 / 100)) ]]; then
    echo "⚠️  WARNING: Less than 90% of IPsec tunnels are healthy"
    echo "   This is not a hard failure but should be investigated"
fi

echo ""
echo "✓ IPsec is enabled (mode: ${IPSEC_ENABLED})"
echo "✓ New metric ovnkube_controller_ipsec_tunnel_ike_child_sa_state is present"
echo "✓ Metric has correct labels (node, remote_ip, local_ip)"
echo "✓ IPsec tunnels: ${INSTALLED_TUNNELS}/${TOTAL_TUNNELS} in INSTALLED state"
echo "✓ Connectivity: ${PASSED_TESTS}/${TOTAL_TESTS} tests passed"
echo ""
echo "====================================="
echo "✅ ALL TESTS PASSED"
echo "====================================="

exit 0
