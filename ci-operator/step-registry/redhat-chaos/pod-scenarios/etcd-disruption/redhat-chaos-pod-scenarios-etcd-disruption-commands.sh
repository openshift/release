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
echo "Checking for egress IP health check configuration..."
echo "SHARED_DIR contents:"
ls -la "$SHARED_DIR"/ 2>/dev/null | head -10 || echo "Cannot list SHARED_DIR"

if [[ -f "$SHARED_DIR/egress-health-check-url" ]]; then
    HEALTH_CHECK_URL=$(cat "$SHARED_DIR/egress-health-check-url" 2>/dev/null)
    if [[ -n "$HEALTH_CHECK_URL" ]]; then
        export HEALTH_CHECK_URL
        echo "✅ Using egress IP health check URL for chaos monitoring: $HEALTH_CHECK_URL"
        
        # Store expected external IP for post-chaos validation
        if [[ -f "$SHARED_DIR/expected-external-ip" ]]; then
            EXPECTED_EXTERNAL_IP=$(cat "$SHARED_DIR/expected-external-ip" 2>/dev/null)
            export EXPECTED_EXTERNAL_IP
            echo "✅ Expected external IP for egress validation: $EXPECTED_EXTERNAL_IP"
        else
            echo "⚠️  No expected external IP file found"
        fi
        echo "✅ Enhanced egress IP health check integration active"
    else
        echo "⚠️  Egress health check URL file is empty, falling back to console"
        console_url=$(oc get routes -n openshift-console console -o jsonpath='{.spec.host}')
        export HEALTH_CHECK_URL=https://$console_url
    fi
else
    echo "⚠️  No egress health check URL file found, falling back to console"
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
