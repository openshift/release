#!/bin/bash
set -x
set -o nounset
set -o pipefail

################################################################################
# Test Overview
################################################################################
# This script deploys a sample OPP application and validates the integration
# with OPP bundle components (Quay, ACS).
#
# Test Cases:
#   1. Deploy OPP Application
#      - Deploys httpd-example application via deploy.sh
#      - Waits for ACM policies to become Compliant
#      - Waits for build completion and deployment availability
#      - Verifies image is pushed to Quay registry (OPP integration)
#      - If ANY step fails, test fails and subsequent cases are skipped
#
#   2. Test ACS Integration
#      - Queries ACS API for httpd-example image
#      - Validates image appears in ACS with CVE scanning results
#      - Only runs if Case 1 passes
#
# Test Reporting:
#   - Results are recorded in JUnit XML format
#   - JUnit XML is generated on exit (via trap) regardless of test results
#   - Script always exits 0 to allow subsequent Prow test steps to run
#   - Individual test failures are visible in Prow UI via JUnit reporting
#
################################################################################

# cd to writable directory
cd /tmp/ || exit 0

# Define all test cases with initial "skipped" status
declare -A TEST_STATUS
declare -A TEST_DURATION
declare -A TEST_FAILURE_MSG

# All test cases that should appear in JUnit XML
ALL_TEST_CASES=(
    "deploy-opp-application"
    "test-acs-integration"
)

# Initialize all tests as failed (will be updated to passed if they succeed)
for test in "${ALL_TEST_CASES[@]}"; do
    TEST_STATUS["$test"]="failed"
    TEST_DURATION["$test"]=0
    TEST_FAILURE_MSG["$test"]="Test did not run"
done

START_TIME=$(date +%s)

# Function to record test result
record_test_result() {
    local test_name="$1"
    local status="$2"  # "passed", "failed", or "skipped"
    local failure_message="${3:-}"
    local duration="${4:-0}"

    TEST_STATUS["$test_name"]="$status"
    TEST_DURATION["$test_name"]="$duration"
    TEST_FAILURE_MSG["$test_name"]="$failure_message"
}

# Function to generate JUnit XML
generate_junit_xml() {
    local junit_file="${ARTIFACT_DIR}/junit_acm-opp-app.xml"
    local total_duration=$(($(date +%s) - START_TIME))

    # Count test results
    local total_tests=${#ALL_TEST_CASES[@]}
    local failed_tests=0

    for test in "${ALL_TEST_CASES[@]}"; do
        if [ "${TEST_STATUS[$test]}" = "failed" ]; then
            failed_tests=$((failed_tests + 1))
        fi
    done

    echo "====== Generating JUnit XML Report ======"
    echo "Total Tests: $total_tests"
    echo "Failed Tests: $failed_tests"
    echo "Passed Tests: $((total_tests - failed_tests))"
    echo "Duration: ${total_duration}s"

    cat > "$junit_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="acm-opp-app" tests="$total_tests" failures="$failed_tests" errors="0" skipped="0" time="$total_duration">
EOF

    # Generate XML for each test case
    for test in "${ALL_TEST_CASES[@]}"; do
        local status="${TEST_STATUS[$test]}"
        local duration="${TEST_DURATION[$test]}"
        local failure_msg="${TEST_FAILURE_MSG[$test]}"

        if [ "$status" = "failed" ]; then
            # Escape XML special characters in failure message
            local escaped_msg
            escaped_msg=$(echo "$failure_msg" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
            echo "    <testcase name=\"$test\" classname=\"acm-opp-app\" time=\"$duration\"><failure message=\"$escaped_msg\"/></testcase>" >> "$junit_file"
        else
            # passed
            echo "    <testcase name=\"$test\" classname=\"acm-opp-app\" time=\"$duration\"/>" >> "$junit_file"
        fi
    done

    cat >> "$junit_file" << EOF
  </testsuite>
</testsuites>
EOF

    echo "JUnit XML generated at: $junit_file"
    cat "$junit_file"
}

################################################################################
# Test Case 1: Deploy OPP Application and Wait for Build/Deployment
################################################################################
run_test_case_1() {
    echo "====== Test Case 1: Deploy OPP Application ======"

    # Download jq
    curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/jq || { echo "ERROR: Failed to download jq"; return 1; }
    chmod +x /tmp/jq

    # Clone and deploy
    git clone -b fix-quay-clair-hpa-with-stabilization https://github.com/tanfengshuang/policy-collection.git || { echo "ERROR: Failed to clone repository"; return 1; }
    cd policy-collection/deploy/ || { echo "ERROR: Failed to cd to deploy directory"; return 1; }
    echo 'y' | ./deploy.sh -p httpd-example -n policies -u https://github.com/gparvin/grc-demo.git -a e2e-opp || { echo "ERROR: deploy.sh failed"; return 1; }

    sleep 60

    # Verify e2e-opp namespace was created
    oc get namespace e2e-opp >/dev/null 2>&1 || { echo "ERROR: Namespace e2e-opp not found, deploy.sh may have failed"; return 1; }

    oc label managedcluster local-cluster oppapps=httpd-example --overwrite

    # Wait for policies to become Compliant
    echo "Waiting for policies to become Compliant..."
    for i in {1..20}; do
        if oc get policies -n policies | grep example | grep -qv "NonCompliant"; then
            echo "Policies are Compliant"; break
        fi
        echo "Try $i/20: Policies not yet compliant, waiting 15s..."
        sleep 15
    done

    # Check initial status
    oc get policies -n policies | grep example || true
    oc get build -n e2e-opp || true
    oc get po -n e2e-opp || true
    oc get deployment -n e2e-opp || true

    # Wait for build to complete
    LATEST_BUILD_NAME=$(oc get builds -n e2e-opp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    [ -z "$LATEST_BUILD_NAME" ] && { LATEST_BUILD_NAME=$(oc start-build httpd-example -n e2e-opp -o name | cut -d'/' -f2) || { echo "ERROR: Failed to start build"; return 1; }; }

    BUILD_STATUS=$(oc get build "$LATEST_BUILD_NAME" -n e2e-opp -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "Initial build status: ${LATEST_BUILD_NAME} is ${BUILD_STATUS}"

    # Only wait if build is not already complete
    if [ "$BUILD_STATUS" != "Complete" ]; then
        BUILD_TIMEOUT=600
        BUILD_ELAPSED=0
        BUILD_CHECK_INTERVAL=15

        while [ $BUILD_ELAPSED -lt $BUILD_TIMEOUT ]; do
            BUILD_STATUS=$(oc get build "$LATEST_BUILD_NAME" -n e2e-opp -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            echo "Build status at ${BUILD_ELAPSED}s: ${BUILD_STATUS}"

            if [ "$BUILD_STATUS" = "Complete" ]; then
                echo "Build ${LATEST_BUILD_NAME} completed successfully"
                break
            elif [ "$BUILD_STATUS" = "Failed" ] || [ "$BUILD_STATUS" = "Error" ] || [ "$BUILD_STATUS" = "Cancelled" ]; then
                echo "!!! Build ${LATEST_BUILD_NAME} failed with status: ${BUILD_STATUS}"

                # Collect diagnostics
                oc get event -n e2e-opp || true
                oc describe buildconfig httpd-example -n e2e-opp || true
                oc describe build "$LATEST_BUILD_NAME" -n e2e-opp || true
                oc get cm -n openshift-config opp-ingres-ca -o yaml || true
                oc get quayintegration quay -o yaml || true
                oc get secret -n policies quay-integration -o yaml || true

                echo "=== Quay Bridge Operator Logs ==="
                OPERATOR_POD_NAME=$(oc get pod -n openshift-operators -l name=quay-bridge-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                if [ -n "$OPERATOR_POD_NAME" ]; then
                    oc logs $OPERATOR_POD_NAME -n openshift-operators -c manager --tail=50 || true
                fi

                # Retry build
                echo "Starting a new build..."
                LATEST_BUILD_NAME=$(oc start-build httpd-example -n e2e-opp -o name | cut -d'/' -f2) || { echo "ERROR: Failed to start new build"; return 1; }
                echo "New build started: ${LATEST_BUILD_NAME}"
                BUILD_ELAPSED=0
                continue
            fi

            sleep $BUILD_CHECK_INTERVAL
            BUILD_ELAPSED=$((BUILD_ELAPSED + BUILD_CHECK_INTERVAL))
        done

        # Final build check
        BUILD_STATUS=$(oc get build "$LATEST_BUILD_NAME" -n e2e-opp -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        [ "$BUILD_STATUS" != "Complete" ] && { echo "ERROR: Build timeout. Final status: ${BUILD_STATUS}"; return 1; }
    fi

    # Wait for deployment
    echo "Waiting for deployment to be available..."
    oc wait --for=condition=Available deployment/httpd-example -n e2e-opp --timeout=5m || { echo "ERROR: Deployment wait failed"; return 1; }

    # Collect deployment info
    oc get build -n e2e-opp || true
    oc get po -n e2e-opp || true
    oc get deployment -n e2e-opp || true

    # Verify image pushed to Quay registry (OPP integration)
    echo "Verifying image pushed to Quay registry..."
    QUAY_HOSTNAME=$(oc get quayintegration quay -o jsonpath='{.spec.quayHostname}') || { echo "ERROR: Failed to get Quay hostname"; oc get quayintegration quay -o yaml || true; return 1; }
    QUAY_MANIFEST_URL="$QUAY_HOSTNAME/v2/openshift_e2e-opp/httpd-example/manifests/latest"
    QUAY_TOKEN=$(oc get secret -n policies quay-integration -o jsonpath='{.data.token}' 2>/dev/null | base64 -d | /tmp/jq -r '.token' 2>/dev/null || echo "")
    [ -z "$QUAY_TOKEN" ] && { echo "ERROR: Failed to get Quay token from quay-integration secret"; oc get secret -n policies quay-integration -o yaml || true; return 1; }
    echo "Checking Quay manifest URL: $QUAY_MANIFEST_URL"

    QUAY_CHECK_RETRIES=20
    QUAY_CHECK_INTERVAL=15

    for attempt in $(seq 1 $QUAY_CHECK_RETRIES); do
        echo "Attempt $attempt/$QUAY_CHECK_RETRIES: Checking if image exists in Quay..."

        HTTP_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $QUAY_TOKEN" "$QUAY_MANIFEST_URL" 2>/dev/null || echo "000")

        if [ "$HTTP_STATUS" = "200" ]; then
            echo "✓ Image successfully pushed to Quay registry"
            return 0
        fi

        echo "⚠️  Image not yet in Quay (HTTP $HTTP_STATUS), waiting..."
        [ $attempt -lt $QUAY_CHECK_RETRIES ] && sleep $QUAY_CHECK_INTERVAL
    done

    # If we reach here, image was never pushed to Quay
    echo "ERROR: Image failed to push to Quay after $((QUAY_CHECK_RETRIES * QUAY_CHECK_INTERVAL)) seconds"
    echo ""
    echo "=== Quay Bridge Operator Diagnostics ==="
    QUAY_BRIDGE_POD=$(oc get pod -n openshift-operators -l name=quay-bridge-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$QUAY_BRIDGE_POD" ]; then
        echo "Quay Bridge Operator logs (last 50 lines with errors):"
        oc logs -n openshift-operators $QUAY_BRIDGE_POD -c manager --tail=50 | grep -E "(ERROR|WARN|httpd-example|e2e-opp)" || true
    else
        echo "Quay Bridge Operator pod not found"
    fi

    echo ""
    echo "=== ImageStream Status ==="
    oc get is -n e2e-opp httpd-example -o yaml | grep -A 5 "status:" || true

    return 1
}

################################################################################
# Test Case 2: Test ACS Integration
################################################################################
run_test_case_2() {
    echo "====== Test Case 2: Test ACS Integration ======"
    echo "NOTE: Test Case 1 has verified image is in Quay. Now waiting for ACS to scan it."

    # Fetch ACS credentials
    echo "Fetching ACS credentials..."
    ACS_PASSWORD=$(oc get secret -n stackrox central-htpasswd -o json | /tmp/jq -r '.data.password' | base64 -d)

    ACS_HOST=$(oc get secret -n stackrox sensor-tls -o json | /tmp/jq -r '.data."acs-host"' | base64 -d)
    echo "ACS Host: ${ACS_HOST}"

    # Query ACS for httpd-example image
    JQ_FILTER='.images[] | select(.name | contains("httpd-example"))'
    ACS_COMMAND="curl -s -k -u admin:${ACS_PASSWORD} https://$ACS_HOST/v1/images"

    RETRIES=10
    RETRY_INTERVAL=30
    IMAGE_FOUND=false

    echo "Waiting for httpd-example image to appear in ACS (max $((RETRIES * RETRY_INTERVAL))s)..."

    for attempt in $(seq 1 $RETRIES); do
        echo "Attempt $attempt/$RETRIES: Querying ACS for httpd-example image..."
	HTTPD_IMAGE_JSON=`$ACS_COMMAND | /tmp/jq "$JQ_FILTER"`
	ID=`echo "$HTTPD_IMAGE_JSON" | /tmp/jq .id`
        if [ "$ID" != "" ]; then
            CVES=`echo "$HTTPD_IMAGE_JSON" | /tmp/jq .cves`
            image=`echo "$HTTPD_IMAGE_JSON" | /tmp/jq .name`
            echo "✓ Success: Found $CVES CVEs for image $image"
            IMAGE_FOUND=true
            break
	fi

        [ $attempt -lt $RETRIES ] && sleep $RETRY_INTERVAL
    done

    # Final check
    if [ "$IMAGE_FOUND" = false ]; then
        echo "ERROR: Image not found in ACS"

        echo "=== Collecting diagnostic information ==="

        echo "=== QuayIntegration Status ==="
        oc get quayintegration quay -o yaml || true

        echo "=== Quay Bridge Operator Logs ==="
        QUAY_BRIDGE_POD=$(oc get pod -n openshift-operators -l name=quay-bridge-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$QUAY_BRIDGE_POD" ]; then
            oc logs -n openshift-operators $QUAY_BRIDGE_POD -c manager --tail=100 || true
        else
            echo "Quay Bridge Operator pod not found"
        fi

        echo "=== ACS Central Logs ==="
        ACS_CENTRAL_POD=$(oc get pod -n stackrox -l app=central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$ACS_CENTRAL_POD" ]; then
            oc logs -n stackrox $ACS_CENTRAL_POD --tail=100 || true
        else
            echo "ACS Central pod not found"
        fi

        echo "=== ACS Scanner Logs ==="
        ACS_SCANNER_POD=$(oc get pod -n stackrox -l app=scanner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$ACS_SCANNER_POD" ]; then
            oc logs -n stackrox $ACS_SCANNER_POD --tail=100 || true
        else
            echo "ACS Scanner pod not found"
        fi

        echo "=== Build Information ==="
        oc get build -n e2e-opp || true
        oc get bc -n e2e-opp httpd-example -o yaml || true

        echo "=== Image Stream Information ==="
        oc get is -n e2e-opp || true
        oc get is -n e2e-opp httpd-example -o yaml || true

        echo "=== All ACS Images (first 10) ==="
        curl -s -k -u admin:${ACS_PASSWORD} https://$ACS_HOST/v1/images | /tmp/jq '.images[:10] | .[] | {name: .name, id: .id}' || true

        return 1
    fi

    return 0
}

################################################################################
# Execute Test Cases
################################################################################
# Set trap to generate JUnit XML on exit
trap generate_junit_xml EXIT

################################################################################
# Pre-flight Check: Verify QuayIntegration exists
################################################################################
echo "====== Pre-flight Check: QuayIntegration ======"

if ! oc get quayintegration quay >/dev/null 2>&1; then
    echo "❌ ERROR: QuayIntegration 'quay' not found!"
    echo "OPP bundle components are not properly configured."
    echo "All test cases will be marked as failed."

    # Mark all tests as failed with specific message
    for test in "${ALL_TEST_CASES[@]}"; do
        TEST_STATUS["$test"]="failed"
        TEST_FAILURE_MSG["$test"]="QuayIntegration not found - OPP bundle not configured"
    done

    # Exit immediately (EXIT trap will generate JUnit XML)
    exit 0
fi

echo "✅ QuayIntegration 'quay' found"
oc get quayintegration quay -o yaml || true
echo ""

################################################################################
# Run Test Cases
################################################################################
# Run Test Case 1
CASE1_START=$(date +%s)
if run_test_case_1; then
    CASE1_DURATION=$(($(date +%s) - CASE1_START))
    record_test_result "deploy-opp-application" "passed" "" "$CASE1_DURATION"
    echo ""
    echo "✅ Test Case 1 Result: PASSED"
    echo ""

    # Run Test Case 2 (ACS Integration)
    CASE2_START=$(date +%s)
    if run_test_case_2; then
        CASE2_DURATION=$(($(date +%s) - CASE2_START))
        record_test_result "test-acs-integration" "passed" "" "$CASE2_DURATION"
        echo ""
        echo "✅ Test Case 2 Result: PASSED"
        echo ""
    else
        CASE2_DURATION=$(($(date +%s) - CASE2_START))
        record_test_result "test-acs-integration" "failed" "ACS integration test failed" "$CASE2_DURATION"
        echo ""
        echo "❌ Test Case 2 Result: FAILED"
        echo ""
    fi
else
    CASE1_DURATION=$(($(date +%s) - CASE1_START))
    echo ""
    echo "❌ Test Case 1 Result: FAILED"
    echo ""
    echo "Test Case 1 failed, skipping remaining test cases..."
    record_test_result "deploy-opp-application" "failed" "OPP application deployment failed" "$CASE1_DURATION"
fi

################################################################################
# Summary
################################################################################
echo "====== Test Summary ======"
echo "All test results will be available in JUnit XML report"
echo ""

# Always exit 0 to allow subsequent test steps to run
# Test results are reported via JUnit XML
exit 0
