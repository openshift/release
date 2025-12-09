#!/bin/bash
set -o nounset
set -o pipefail

################################################################################
# Wait for Debug
################################################################################
# This step pauses test execution to allow manual inspection and debugging.
################################################################################

WAIT_DURATION="${WAIT_DURATION:-7200}"  # Default: 2 hours (in seconds)

echo "====== OPP Debug Wait Step ======"
echo ""
echo "Cluster is ready for debugging."
echo "Pausing for ${WAIT_DURATION} seconds ($(($WAIT_DURATION / 60)) minutes, $(($WAIT_DURATION / 3600)) hours)"
echo ""
echo "You can now exec into the Prow pod to run oc commands."
echo ""

# Display some useful information
echo "--- Current Cluster State ---"
echo ""
echo "QuayIntegration:"
oc get quayintegration -A 2>/dev/null || echo "  Not found"
echo ""

echo "ACM Policies:"
oc get policies -n policies 2>/dev/null || echo "  Not found"
echo ""

echo "Nodes:"
oc get nodes
echo ""

# Check Quay and Clair health
echo "--- Quay Component Health Check ---"
echo ""

quay_ns=$(oc get quayregistry --all-namespaces 2>/dev/null | tail -n1 | awk '{print $1}')
if [ -n "$quay_ns" ]; then
    echo "Quay namespace: $quay_ns"
    echo ""

    # Check Quay pods
    echo "Quay App Pods:"
    oc get pods -n "$quay_ns" -l quay-component=quay-app -o wide 2>/dev/null || echo "  Not found"
    echo ""

    # Check Clair pods
    echo "Clair App Pods:"
    oc get pods -n "$quay_ns" -l quay-component=clair-app -o wide 2>/dev/null || echo "  Not found"

    # Count ready Clair pods
    clair_ready=$(oc get pods -n "$quay_ns" -l quay-component=clair-app --field-selector=status.phase=Running -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length' 2>/dev/null || echo "0")
    clair_total=$(oc get pods -n "$quay_ns" -l quay-component=clair-app --no-headers 2>/dev/null | wc -l)

    echo ""
    echo "Clair Status: $clair_ready/$clair_total pods ready"

    if [ "$clair_ready" -lt 2 ]; then
        echo "⚠️  WARNING: Less than 2 Clair pods are ready!"
        echo "   This may cause Quay functionality issues."
        echo ""
        echo "Clair Pod Details:"
        oc describe pods -n "$quay_ns" -l quay-component=clair-app 2>/dev/null | grep -A 10 "Events:" || true
    else
        echo "✓ Clair pods healthy"
    fi

    echo ""

    # Check Quay registry endpoint
    quay_registry=$(oc get quayregistry -n "$quay_ns" 2>/dev/null | tail -n1 | awk '{print $1}')
    if [ -n "$quay_registry" ]; then
        registry_endpoint=$(oc get quayregistry -n "$quay_ns" "$quay_registry" -o jsonpath='{.status.registryEndpoint}' 2>/dev/null)
        echo "Quay Registry Endpoint: $registry_endpoint"

        # Try to check Quay health endpoint
        quay_pod=$(oc get pod -n "$quay_ns" -l quay-component=quay-app -o name 2>/dev/null | head -1)
        if [ -n "$quay_pod" ]; then
            echo ""
            echo "Quay Health Check:"
            oc exec -n "$quay_ns" "$quay_pod" -c quay-app -- curl -s http://localhost:8080/health/instance 2>/dev/null | jq . || echo "  Could not check health endpoint"
        fi
    fi
else
    echo "  No Quay registry found"
fi
echo ""

echo "====== Entering sleep mode for ${WAIT_DURATION} seconds ======"
echo "Start time: $(date)"
echo ""

# Sleep for the specified duration
sleep ${WAIT_DURATION}

echo ""
echo "====== Sleep completed ======"
echo "End time: $(date)"
echo ""

exit 0
