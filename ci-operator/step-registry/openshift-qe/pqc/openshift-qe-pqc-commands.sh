#!/bin/bash

set -e

echo "==> Applying APIServer TLS configuration..."
oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  name: cluster
spec:
  tlsSecurityProfile:
    type: Custom
    custom:
      ciphers:
      - ECDHE-ECDSA-AES128-GCM-SHA256
      minTLSVersion: VersionTLS12
      groups:
      - X25519MLKEM768
EOF

echo ""
echo "==> Waiting for kube-apiserver operator to start progressing..."
sleep 5

# Wait for the kube-apiserver operator to become progressing
timeout 300 bash -c 'while ! oc get co kube-apiserver -o jsonpath="{.status.conditions[?(@.type==\"Progressing\")].status}" | grep -q "True"; do sleep 5; done' || {
    echo "Warning: kube-apiserver did not enter Progressing state within 5 minutes"
}

echo "==> kube-apiserver is now progressing. Waiting for rollout to complete..."
echo ""

# Monitor the rollout
start_time=$(date +%s)
while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))

    # Get cluster operator status with timeout handling
    progressing=$(oc get co kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "unknown")
    available=$(oc get co kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "unknown")
    degraded=$(oc get co kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "unknown")

    # Get the current TLS profile from the apiserver
    current_tls=$(oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile.type}' 2>/dev/null || echo "unknown")

    # Display status
    echo "[$(date +%H:%M:%S)] Elapsed: ${elapsed}s | Available: $available | Progressing: $progressing | Degraded: $degraded | TLS Profile: $current_tls"

    # Skip checks if we got timeout/errors
    if [ "$progressing" = "unknown" ] || [ "$available" = "unknown" ] || [ "$degraded" = "unknown" ]; then
        echo "  ⚠ API query timeout or error - will retry..."
        sleep 10
        continue
    fi

    # Check if rollout is complete
    if [ "$progressing" = "False" ] && [ "$available" = "True" ] && [ "$degraded" = "False" ]; then
        echo ""
        echo "==> Rollout complete!"
        echo ""

        # Verify the configuration was applied
        echo "==> Verifying TLS configuration:"
        oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile}' | jq .

        echo ""
        echo "==> Checking applied cipher suites and TLS version:"
        echo "Expected cipher: ECDHE-ECDSA-AES128-GCM-SHA256"
        echo "Expected TLS version: VersionTLS12"
        echo "Expected groups: X25519MLKEM768"
        echo ""

        # Check actual cipher configuration
        actual_ciphers=$(oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile.custom.ciphers[*]}')
        actual_tls=$(oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile.custom.minTLSVersion}')
        actual_groups=$(oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile.custom.groups[*]}')

        echo "Actual cipher:     $actual_ciphers"
        echo "Actual TLS:        $actual_tls"
        echo "Actual groups:     $actual_groups"
        echo ""

        # Verify settings match
        if [[ "$actual_ciphers" == "ECDHE-ECDSA-AES128-GCM-SHA256" ]] && \
           [[ "$actual_tls" == "VersionTLS12" ]] && \
           [[ "$actual_groups" == "X25519MLKEM768" ]]; then
            echo "✓ Crypto settings verified correctly!"
        else
            echo "⚠ Warning: Crypto settings may not match expected values"
        fi

        echo ""
        echo "==> API Server pods:"
        oc get pods -n openshift-kube-apiserver -l app=openshift-kube-apiserver --sort-by=.metadata.creationTimestamp
        echo ""
        echo "==> Checking kube-apiserver runtime TLS curve configuration:"
        KAPI_CONFIG=$(oc get cm config -n openshift-kube-apiserver -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
        if echo "$KAPI_CONFIG" | grep -q "X25519MLKEM768"; then
           echo "✓ PQ hybrid (X25519MLKEM768) is present in kube-apiserver runtime config"
        else
           echo "⚠ X25519MLKEM768 NOT found in kube-apiserver runtime config — may have fallen back to classical"
           echo "namedCurves in runtime config:"
           echo "$KAPI_CONFIG" | grep -A5 "namedCurves" || echo "(namedCurves not found)"
        fi
        echo ""
        echo "==> Testing actual TLS key exchange negotiation:"
        API_ENDPOINT=$(oc whoami --show-server | sed 's|https://||')
        OPENSSL_OUT=$(echo Q | timeout 10 openssl s_client \
            -connect "${API_ENDPOINT}" \
            -tls1_3 \
            -curves X25519MLKEM768:X25519 2>&1) || true
        SERVER_KEY=$(echo "$OPENSSL_OUT" | grep -i "Server Temp Key" || true)
        if echo "$SERVER_KEY" | grep -qi "X25519MLKEM768"; then
            echo "✓ PQ hybrid (X25519MLKEM768) negotiated in TLS handshake"
        elif echo "$SERVER_KEY" | grep -qi "X25519"; then
            echo "⚠ TLS handshake fell back to classical X25519 — PQ not negotiated"
            echo "$SERVER_KEY"
        else
            echo "Note: openssl on this host may not support X25519MLKEM768 — handshake negotiation unverifiable"
            echo "Provide an OQS-enabled openssl build to confirm end-to-end PQ negotiation"
        fi
        break
    fi

    # Check for degraded state
    if [ "$degraded" = "True" ]; then
        echo ""
        echo "WARNING: kube-apiserver is in a degraded state!"
        echo "Degraded message:"
        oc get co kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}'
        echo ""
    fi

    # Timeout after 60 minutes (increased for slow rollouts)
    if [ $elapsed -gt 3600 ]; then
        echo ""
        echo "ERROR: Rollout did not complete within 60 minutes"
        echo ""
        echo "Final cluster operator status:"
        oc get co kube-apiserver -o yaml 2>&1 || echo "Failed to get cluster operator status"
        exit 1
    fi

    sleep 10
done

echo ""
echo "==> Change successfully applied and rolled out in ${elapsed} seconds"