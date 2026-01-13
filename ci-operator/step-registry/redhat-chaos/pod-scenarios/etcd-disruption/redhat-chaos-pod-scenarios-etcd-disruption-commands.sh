#!/bin/bash
set -o errexit

ES_PASSWORD=$(cat "/secret/es/password")
ES_USERNAME=$(cat "/secret/es/username")

export ES_PASSWORD
export ES_USERNAME

if [[ -n $ES_PASSWORD ]]; then
    export ES_SERVER="https://search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
fi

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config

export KRKN_KUBE_CONFIG=$KUBECONFIG
export NAMESPACE=$TARGET_NAMESPACE 
export ALERTS_PATH="/home/krkn/kraken/config/alerts_openshift.yaml"
telemetry_password=$(cat "/secret/telemetry/telemetry_password" || true)
export TELEMETRY_PASSWORD=$telemetry_password

oc get nodes --kubeconfig $KRKN_KUBE_CONFIG

# Use egress IP health check if available, fallback to console
if [[ -f "$SHARED_DIR/egress-health-check-url" ]]; then
    HEALTH_CHECK_URL=$(cat "$SHARED_DIR/egress-health-check-url")
    export HEALTH_CHECK_URL
    echo "Using egress IP health check URL for chaos monitoring: $HEALTH_CHECK_URL"
    
    # Store expected external IP for post-chaos validation
    if [[ -f "$SHARED_DIR/expected-external-ip" ]]; then
        EXPECTED_EXTERNAL_IP=$(cat "$SHARED_DIR/expected-external-ip")
        export EXPECTED_EXTERNAL_IP
        echo "Expected external IP for egress validation: $EXPECTED_EXTERNAL_IP"
        
        # Create a custom health check script that validates content, not just HTTP 200
        cat > /tmp/egress-health-check.sh << 'EOF'
#!/bin/bash
# Custom health check that validates egress IP functionality content
set -o pipefail

NAMESPACE="${TARGET_NAMESPACE:-egress-ip-test}"
TIMEOUT=30

# Create temporary pod to test egress IP functionality
POD_NAME="health-check-$(date +%s)"
cat << PODEOF | oc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
  - name: curl
    image: registry.redhat.io/ubi9/ubi:latest
    command: ["/bin/sh", "-c", "curl -s --max-time 10 https://httpbin.org/ip 2>/dev/null | jq -r .origin 2>/dev/null || echo 'FAILED'"]
PODEOF

# Wait for pod completion and get result
if oc wait --for=condition=Ready pod/$POD_NAME -n "$NAMESPACE" --timeout=${TIMEOUT}s >/dev/null 2>&1; then
    sleep 2  # Allow command to complete
    ACTUAL_IP=$(oc logs pod/$POD_NAME -n "$NAMESPACE" 2>/dev/null | head -n1 | tr -d '\r\n')
    oc delete pod $POD_NAME -n "$NAMESPACE" >/dev/null 2>&1
    
    if [[ "$ACTUAL_IP" != "FAILED" && -n "$ACTUAL_IP" ]]; then
        echo "SUCCESS: Egress IP health check passed - External connectivity via $ACTUAL_IP"
        exit 0
    else
        echo "FAILED: Egress IP health check - No valid external connectivity"
        exit 1
    fi
else
    oc delete pod $POD_NAME -n "$NAMESPACE" >/dev/null 2>&1
    echo "FAILED: Egress IP health check - Pod timeout/failure"
    exit 1
fi
EOF
        chmod +x /tmp/egress-health-check.sh
        echo "Created enhanced egress IP health check with content validation"
    fi
else
    console_url=$(oc get routes -n openshift-console console -o jsonpath='{.spec.host}')
    export HEALTH_CHECK_URL=https://$console_url
    echo "Using console health check URL: $HEALTH_CHECK_URL"
fi
set -o nounset
set -o pipefail
set -x

./pod-scenarios/prow_run.sh
rc=$?
echo "Done running the test!" 

cat /tmp/*.log 
if [[ $TELEMETRY_EVENTS_BACKUP == "True" ]]; then
    cp /tmp/events.json ${ARTIFACT_DIR}/events.json
fi

echo "Return code: $rc"
exit $rc
