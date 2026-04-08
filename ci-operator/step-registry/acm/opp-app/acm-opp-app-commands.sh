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
#      - Waits for deployment availability (implicitly waits for build)
#      - Verifies deployment is running successfully
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
    curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/jq || return 1
    chmod +x /tmp/jq

    # Clone and deploy
    git clone https://github.com/stolostron/policy-collection.git || return 1
    cd policy-collection/deploy/ || return 1
    echo 'y' | ./deploy.sh -p httpd-example -n policies -u https://github.com/gparvin/grc-demo.git -a e2e-opp || return 1

    sleep 60

    # Verify e2e-opp namespace was created
    oc get namespace e2e-opp >/dev/null 2>&1 || return 1

    oc label managedcluster local-cluster oppapps=httpd-example --overwrite

    # Check initial status
    oc get policies -n policies | grep example || true
    oc get build -n e2e-opp || true
    oc get po -n e2e-opp || true
    oc get deployment -n e2e-opp || true

    # Trigger build if needed
    LATEST_BUILD_NAME=$(oc get builds -n e2e-opp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
    [ -z "$LATEST_BUILD_NAME" ] && { LATEST_BUILD_NAME=$(oc start-build httpd-example -n e2e-opp -o name | cut -d'/' -f2) || return 1; }
    echo "Monitoring build: ${LATEST_BUILD_NAME}"

    # Wait for deployment (which implicitly waits for build to complete)
    echo "Waiting for deployment to be available (timeout: 10m)..."
    if ! oc wait --for=condition=Available deployment/httpd-example -n e2e-opp --timeout=10m; then
        echo "❌ ERROR: Deployment did not become available"

        # Collect diagnostics to understand why deployment failed
        echo "=== Build Status ==="
        LATEST_BUILD=$(oc get builds -n e2e-opp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$LATEST_BUILD" ]; then
            BUILD_STATUS=$(oc get build "$LATEST_BUILD" -n e2e-opp -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            echo "Latest build: $LATEST_BUILD"
            echo "Build status: $BUILD_STATUS"

            if [ "$BUILD_STATUS" != "Complete" ]; then
                echo "=== Build Details ==="
                oc describe build "$LATEST_BUILD" -n e2e-opp || true
                oc describe buildconfig httpd-example -n e2e-opp || true
            fi
        fi

        echo "=== Events ==="
        oc get event -n e2e-opp || true

        echo "=== Deployment Status ==="
        oc get deployment -n e2e-opp || true
        oc describe deployment httpd-example -n e2e-opp || true

        echo "=== Pod Status ==="
        oc get po -n e2e-opp || true

        echo "=== ImageStream Status ==="
        oc get is -n e2e-opp httpd-example -o yaml | grep -A 10 "status:" || true

        echo "=== Quay Integration Status ==="
        oc get quayintegration quay -o yaml || true
        oc get cm -n openshift-config opp-ingres-ca -o yaml || true
        oc get secret -n policies quay-integration -o yaml || true

        echo "=== Quay Bridge Operator Logs ==="
        OPERATOR_POD=$(oc get pod -n openshift-operators -l name=quay-bridge-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        [ -n "$OPERATOR_POD" ] && oc logs -n openshift-operators "$OPERATOR_POD" -c manager --tail=100 || true

        return 1
    fi

    echo "✅ Deployment is available"

    # Collect final status
    oc get build,po,deployment -n e2e-opp || true
    oc get is -n e2e-opp httpd-example -o yaml | grep -A 5 "status:" || true

    return 0
}

################################################################################
# Test Case 2: Test ACS Integration
################################################################################
run_test_case_2() {
    echo "====== Test Case 2: Test ACS Integration ======"
    echo "NOTE: Waiting for ACS to scan the httpd-example image built in Test Case 1."

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
        HTTPD_IMAGE_JSON=$($ACS_COMMAND | /tmp/jq "$JQ_FILTER")
        ID=$(echo "$HTTPD_IMAGE_JSON" | /tmp/jq .id)
        if [ "$ID" != "" ]; then
            CVES=$(echo "$HTTPD_IMAGE_JSON" | /tmp/jq .cves)
            image=$(echo "$HTTPD_IMAGE_JSON" | /tmp/jq .name)
            echo "✅ Success: Found $CVES CVEs for image $image"
            IMAGE_FOUND=true
            break
        fi

        [ $attempt -lt $RETRIES ] && sleep $RETRY_INTERVAL
    done

    [ "$IMAGE_FOUND" = true ] || return 1

    return 0
}

################################################################################
# Test Execution Setup
################################################################################
# Set trap to generate JUnit XML on exit (regardless of success or failure)
trap generate_junit_xml EXIT

################################################################################
# Pre-flight Checks
################################################################################
echo "====== Pre-flight Check: QuayIntegration ======"

if ! oc get quayintegration quay >/dev/null 2>&1; then
    echo "❌ ERROR: QuayIntegration 'quay' not found!"
    echo "OPP bundle components are not properly configured."
    echo "Cannot proceed with testing - marking all test cases as failed."

    # Mark all tests as failed with specific message
    for test in "${ALL_TEST_CASES[@]}"; do
        TEST_STATUS["$test"]="failed"
        TEST_FAILURE_MSG["$test"]="QuayIntegration not found - OPP bundle not configured"
    done

    # Exit immediately (EXIT trap will generate JUnit XML)
    exit 0
fi

echo "✅ QuayIntegration quay found"
oc get quayintegration quay -o yaml || true

################################################################################
# Execute Test Cases
################################################################################
# Run Test Case 1
CASE1_START=$(date +%s)
if run_test_case_1; then
    CASE1_DURATION=$(($(date +%s) - CASE1_START))
    record_test_result "deploy-opp-application" "passed" "" "$CASE1_DURATION"
    echo "✅ Test Case 1 (Deploy OPP Application) Result: PASSED"

    # Run Test Case 2 (ACS Integration)
    CASE2_START=$(date +%s)
    if run_test_case_2; then
        CASE2_DURATION=$(($(date +%s) - CASE2_START))
        record_test_result "test-acs-integration" "passed" "" "$CASE2_DURATION"
        echo "✅ Test Case 2 (Test ACS Integration) Result: PASSED"
    else
        CASE2_DURATION=$(($(date +%s) - CASE2_START))
        record_test_result "test-acs-integration" "failed" "ACS integration test failed" "$CASE2_DURATION"
        echo "❌ Test Case 2 (Test ACS Integration) Result: FAILED"
    fi
else
    CASE1_DURATION=$(($(date +%s) - CASE1_START))
    echo "❌ Test Case 1 (Deploy OPP Application) Result: FAILED"
    echo "Test Case 1 failed, skipping remaining test cases..."
    record_test_result "deploy-opp-application" "failed" "OPP application deployment failed" "$CASE1_DURATION"
fi

echo "====== Test Summary ======"
echo "All test results will be available in JUnit XML report"

# Always exit 0 to allow subsequent test steps to run
# Test results are reported via JUnit XML
exit 0
