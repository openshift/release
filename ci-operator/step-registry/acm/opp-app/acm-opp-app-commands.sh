#!/bin/bash
set -x
set -o nounset
set -o pipefail
# NOTE: Do NOT use 'set -o errexit' because we want to run all tests
# and report results via JUnit XML

################################################################################
# Test Overview
################################################################################
# This script deploys a sample OPP application and validates the integration
# with OPP bundle components (Quay, ACS).
#
# Test Cases:
#   1. Deploy OPP Application
#      - Downloads jq binary for JSON parsing
#      - Clones policy-collection repository
#      - Deploys httpd-example application via deploy.sh
#      - Labels managed cluster for policy placement
#      - Waits for build completion (with retry on failure)
#      - Waits for deployment to become available
#      - If ANY step fails, test fails and Case 2 is skipped
#
#   2. Test ACS Integration
#      - Fetches ACS credentials (password and host)
#      - Queries ACS API for httpd-example image
#      - Retries up to 10 times with 30s intervals
#      - Validates image appears in ACS with CVE scanning results
#      - Only runs if Case 1 passes
#
# Test Reporting:
#   - Results are recorded in JUnit XML format
#   - Each test case reports pass/fail with duration and failure messages
#   - JUnit XML is generated on exit (via trap) regardless of test results
#   - Script always exits 0 to allow subsequent Prow test steps to run
#   - Individual test failures are visible in Prow UI via JUnit reporting
#
################################################################################

# cd to writable directory
cd /tmp/

# Initialize test results
TEST_RESULTS=()
TOTAL_TESTS=0
FAILED_TESTS=0
START_TIME=$(date +%s)

# Function to record test result
record_test_result() {
    local test_name="$1"
    local status="$2"  # "passed" or "failed"
    local failure_message="${3:-}"
    local duration="${4:-0}"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [ "$status" = "failed" ]; then
        FAILED_TESTS=$((FAILED_TESTS + 1))
        # Escape XML special characters in failure message
        local escaped_msg=$(echo "$failure_message" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
        TEST_RESULTS+=("<testcase name=\"$test_name\" classname=\"acm-opp-app\" time=\"$duration\"><failure message=\"$escaped_msg\"/></testcase>")
    else
        TEST_RESULTS+=("<testcase name=\"$test_name\" classname=\"acm-opp-app\" time=\"$duration\"/>")
    fi
}

# Function to generate JUnit XML
generate_junit_xml() {
    local junit_file="${ARTIFACT_DIR}/junit_acm-opp-app.xml"
    local total_duration=$(($(date +%s) - START_TIME))

    echo "========================================="
    echo "Generating JUnit XML Report"
    echo "========================================="
    echo "Total Tests: $TOTAL_TESTS"
    echo "Failed Tests: $FAILED_TESTS"
    echo "Duration: ${total_duration}s"

    cat > "$junit_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="acm-opp-app" tests="$TOTAL_TESTS" failures="$FAILED_TESTS" errors="0" skipped="0" time="$total_duration">
EOF

    for result in "${TEST_RESULTS[@]}"; do
        echo "    $result" >> "$junit_file"
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
    echo "========================================="
    echo "Test Case 1: Deploy OPP Application"
    echo "========================================="
    local test_start=$(date +%s)

    # Set trap to auto-record failure on any command failure
    trap 'record_test_result "deploy-opp-application" "failed" "OPP application deployment failed" $(($(date +%s) - test_start)); return 1' ERR
    set -e  # Enable errexit for this function only

    # Download jq
    echo "Downloading jq..."
    curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/jq
    chmod +x /tmp/jq
    /tmp/jq --version >/dev/null 2>&1
    echo "jq installed successfully"

    # Clone and deploy
    git clone https://github.com/stolostron/policy-collection.git
    cd policy-collection/deploy/
    echo 'y' | ./deploy.sh -p httpd-example -n policies -u https://github.com/tanfengshuang/grc-demo.git -a e2e-opp

    # Wait for resources
    sleep 60

    # Label managed cluster
    oc label managedcluster local-cluster oppapps=httpd-example --overwrite

    # Check initial status
    oc get policies -n policies | grep example || true
    oc get build -n e2e-opp || true
    oc get po -n e2e-opp || true
    oc get deployment -n e2e-opp || true

    # Wait for build to complete
    LATEST_BUILD_NAME=$(oc get builds -n e2e-opp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    [ -z "$LATEST_BUILD_NAME" ] && { echo "ERROR: No build found"; return 1; }

    BUILD_STATUS=$(oc get build "$LATEST_BUILD_NAME" -n e2e-opp -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "Initial build status: ${LATEST_BUILD_NAME} is ${BUILD_STATUS}"

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
            echo "=== Events ==="
            oc get event -n e2e-opp || true
            echo "=== BuildConfig Details ==="
            oc describe buildconfig httpd-example -n e2e-opp || true
            echo "=== Build Details ==="
            oc describe build "$LATEST_BUILD_NAME" -n e2e-opp || true
            echo "=== Quay Bridge Operator Logs ==="
            OPERATOR_POD_NAME=$(oc get pod -n openshift-operators -l name=quay-bridge-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$OPERATOR_POD_NAME" ]; then
                oc logs $OPERATOR_POD_NAME -n openshift-operators -c manager --tail=50 || true
            fi

            # Retry build
            echo "Starting a new build..."
            LATEST_BUILD_NAME=$(oc start-build httpd-example -n e2e-opp -o name 2>/dev/null | cut -d'/' -f2 || echo "")
            [ -z "$LATEST_BUILD_NAME" ] && { echo "ERROR: Build retry failed"; return 1; }
            echo "New build started: ${LATEST_BUILD_NAME}"
            BUILD_ELAPSED=0
            continue
        fi

        sleep $BUILD_CHECK_INTERVAL
        BUILD_ELAPSED=$((BUILD_ELAPSED + BUILD_CHECK_INTERVAL))
    done

    # Final build check
    BUILD_STATUS=$(oc get build "$LATEST_BUILD_NAME" -n e2e-opp -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$BUILD_STATUS" != "Complete" ]; then
        echo "ERROR: Build timeout. Final status: ${BUILD_STATUS}"
        oc get build "$LATEST_BUILD_NAME" -n e2e-opp -o yaml || true
        return 1
    fi

    # Wait for deployment
    echo "Waiting for deployment to be available..."
    oc wait --for=condition=Available deployment/httpd-example -n e2e-opp --timeout=5m 2>/dev/null

    # Collect deployment info
    oc get policies -n policies | grep example || true
    oc get build -n e2e-opp || true
    oc get po -n e2e-opp || true
    oc get deployment -n e2e-opp || true
    oc get cm -n openshift-config opp-ingres-ca -o yaml || true
    oc get quayintegration quay -o yaml || true
    oc get secret -n policies quay-integration -o yaml || true

    # Test passed - disable trap and record success
    set +e
    trap - ERR
    record_test_result "deploy-opp-application" "passed" "" $(($(date +%s) - test_start))
    echo ""
    echo "Test Case 1 Result: PASSED"
    echo ""
    return 0
}

################################################################################
# Test Case 2: Test ACS Integration
################################################################################
run_test_case_2() {
    echo "========================================="
    echo "Test Case 2: Test ACS Integration"
    echo "========================================="
    local test_start=$(date +%s)

    # Set trap to auto-record failure
    trap 'record_test_result "test-acs-integration" "failed" "ACS integration test failed" $(($(date +%s) - test_start)); return 1' ERR
    set -e

    # Fetch ACS credentials
    echo "Fetching ACS credentials..."
    ACS_PASSWORD=$(oc get secret -n stackrox central-htpasswd -o json 2>/dev/null | /tmp/jq -r '.data.password' | base64 -d 2>/dev/null || echo "")
    [ -z "$ACS_PASSWORD" ] && { echo "ERROR: Failed to retrieve ACS password"; return 1; }

    ACS_HOST=$(oc get secret -n stackrox sensor-tls -o json 2>/dev/null | /tmp/jq -r '.data."acs-host"' | base64 -d 2>/dev/null || echo "")
    [ -z "$ACS_HOST" ] && { echo "ERROR: Failed to retrieve ACS host"; return 1; }
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

        ACS_RESPONSE=$($ACS_COMMAND 2>&1 || echo "")

        # Check if response is empty
        if [ -z "$ACS_RESPONSE" ]; then
            echo "WARNING: ACS API returned empty response"
            [ $attempt -eq $RETRIES ] && { echo "ERROR: ACS API unreachable"; return 1; }
        # Check if response is valid JSON
        elif echo "$ACS_RESPONSE" | grep -q '^{'; then
            HTTPD_IMAGE_JSON=$(echo "$ACS_RESPONSE" | /tmp/jq "$JQ_FILTER" 2>/dev/null || echo "")
            ID=$(echo "$HTTPD_IMAGE_JSON" | /tmp/jq -r '.id' 2>/dev/null || echo "")

            if [ -n "$ID" ] && [ "$ID" != "null" ]; then
                CVES=$(echo "$HTTPD_IMAGE_JSON" | /tmp/jq '.cves' 2>/dev/null || echo "unknown")
                IMAGE_NAME=$(echo "$HTTPD_IMAGE_JSON" | /tmp/jq -r '.name' 2>/dev/null || echo "httpd-example")
                echo "✓ Success: Found $CVES CVEs for image $IMAGE_NAME"
                echo "Image ID: $ID"
                IMAGE_FOUND=true
                break
            else
                echo "Image not found in ACS response yet"
            fi
        else
            echo "WARNING: ACS API call failed with: ${ACS_RESPONSE:0:200}"
            [ $attempt -eq $RETRIES ] && { echo "ERROR: ACS API failed"; return 1; }
        fi

        [ $attempt -lt $RETRIES ] && sleep $RETRY_INTERVAL
    done

    [ "$IMAGE_FOUND" = false ] && { echo "ERROR: Image not found in ACS"; return 1; }

    # Test passed - disable trap and record success
    set +e
    trap - ERR
    record_test_result "test-acs-integration" "passed" "" $(($(date +%s) - test_start))
    echo ""
    echo "Test Case 2 Result: PASSED"
    echo ""
    return 0
}

################################################################################
# Execute Test Cases
################################################################################
# Set trap to generate JUnit XML on exit
trap generate_junit_xml EXIT

# Run Test Case 1
if run_test_case_1; then
    # Test Case 1 passed, continue to Test Case 2
    run_test_case_2
else
    echo "Test Case 1 failed, skipping Test Case 2..."
fi

################################################################################
# Summary
################################################################################
echo "========================================="
echo "Test Summary"
echo "========================================="
echo "Total Tests: $TOTAL_TESTS"
echo "Failed Tests: $FAILED_TESTS"
echo "Passed Tests: $((TOTAL_TESTS - FAILED_TESTS))"
echo ""

# Always exit 0 to allow subsequent test steps to run
# Test results are reported via JUnit XML
exit 0
