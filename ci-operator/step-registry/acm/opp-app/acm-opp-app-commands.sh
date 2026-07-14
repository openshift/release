#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

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
typeset -A testStatus
typeset -A testDuration
typeset -A testFailureMsg

# All test cases that should appear in JUnit XML
typeset -a allTestCasesArr=(
    "deploy-opp-application"
    "test-acs-integration"
)

# Initialize all tests as failed (will be updated to passed if they succeed)
typeset test=""
for test in "${allTestCasesArr[@]}"; do
    testStatus["${test}"]="failed"
    testDuration["${test}"]=0
    testFailureMsg["${test}"]="Test did not run"
done

typeset -i startTime=0
startTime=$(date +%s)

# Function to record test result
RecordTestResult() {
    typeset testName="${1:-}"; (($#)) && shift
    typeset status="${1:-}"; (($#)) && shift
    typeset failureMessage="${1:-}"; (($#)) && shift
    typeset duration="${1:-0}"; (($#)) && shift

    testStatus["${testName}"]="${status}"
    testDuration["${testName}"]="${duration}"
    testFailureMsg["${testName}"]="${failureMessage}"
}

# Function to generate JUnit XML
GenerateJunitXml() {
    typeset junitFile="${ARTIFACT_DIR}/junit_acm-opp-app.xml"
    typeset -i totalDuration=$(( $(date +%s) - startTime ))

    # Count test results
    typeset -i totalTests=${#allTestCasesArr[@]}
    typeset -i failedTests=0
    typeset -i skippedTests=0

    for test in "${allTestCasesArr[@]}"; do
        if [ "${testStatus[${test}]}" = "failed" ]; then
            failedTests=$((failedTests + 1))
        elif [ "${testStatus[${test}]}" = "skipped" ]; then
            skippedTests=$((skippedTests + 1))
        fi
    done

    : "Generating JUnit XML Report"
    : "Total Tests: ${totalTests}"
    : "Failed Tests: ${failedTests}"
    : "Skipped Tests: ${skippedTests}"
    : "Passed Tests: $((totalTests - failedTests - skippedTests))"
    : "Duration: ${totalDuration}s"

    cat > "${junitFile}" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="acm-opp-app" tests="${totalTests}" failures="${failedTests}" errors="0" skipped="${skippedTests}" time="${totalDuration}">
EOF

    # Generate XML for each test case
    for test in "${allTestCasesArr[@]}"; do
        typeset status="${testStatus[${test}]}"
        typeset duration="${testDuration[${test}]}"
        typeset failureMsg="${testFailureMsg[${test}]}"

        if [ "${status}" = "failed" ]; then
            typeset escapedMsg=""
            escapedMsg=$(echo "${failureMsg}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
            echo "    <testcase name=\"${test}\" classname=\"acm-opp-app\" time=\"${duration}\"><failure message=\"${escapedMsg}\"/></testcase>" >> "${junitFile}"
        elif [ "${status}" = "skipped" ]; then
            typeset escapedMsg=""
            escapedMsg=$(echo "${failureMsg}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
            echo "    <testcase name=\"${test}\" classname=\"acm-opp-app\" time=\"${duration}\"><skipped message=\"${escapedMsg}\"/></testcase>" >> "${junitFile}"
        else
            echo "    <testcase name=\"${test}\" classname=\"acm-opp-app\" time=\"${duration}\"/>" >> "${junitFile}"
        fi
    done

    cat >> "${junitFile}" << EOF
  </testsuite>
</testsuites>
EOF

    : "JUnit XML generated at: ${junitFile}"
    cat "${junitFile}"
}

################################################################################
# Test Case 1: Deploy OPP Application and Wait for Build/Deployment
################################################################################
RunTestCase1() {
    : "====== Test Case 1: Deploy OPP Application ======"

    # Download jq
    curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/jq || return 1
    chmod +x /tmp/jq

    # Clone and deploy
    git clone https://github.com/stolostron/policy-collection.git || return 1
    cd policy-collection/deploy/ || return 1
    echo 'y' | ./deploy.sh -p httpd-example -n policies -u https://github.com/gparvin/grc-demo.git -a e2e-opp || return 1

    sleep 60

    # Verify e2e-opp namespace was created
    oc get namespace e2e-opp >/dev/null || return 1

    oc label managedcluster local-cluster oppapps=httpd-example --overwrite

    # Check initial status
    oc get policies -n policies | grep example || true
    oc get build -n e2e-opp || true
    oc get po -n e2e-opp || true
    oc get deployment -n e2e-opp || true

    # Trigger build if needed
    typeset latestBuildName=""
    latestBuildName=$(oc get builds -n e2e-opp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' || echo "")
    [ -z "${latestBuildName}" ] && { latestBuildName=$(oc start-build httpd-example -n e2e-opp -o name | cut -d'/' -f2) || return 1; }
    : "Monitoring build: ${latestBuildName}"

    # Wait for deployment (which implicitly waits for build to complete)
    : "Waiting for deployment to be available (timeout: 10m)..."
    if ! oc wait --for=condition=Available deployment/httpd-example -n e2e-opp --timeout=10m; then
        : "ERROR: Deployment did not become available"

        # Collect diagnostics to understand why deployment failed
        : "=== Build Status ==="
        typeset latestBuild=""
        latestBuild=$(oc get builds -n e2e-opp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' || echo "")
        if [ -n "${latestBuild}" ]; then
            typeset buildStatus=""
            buildStatus=$(oc get build "${latestBuild}" -n e2e-opp -o jsonpath='{.status.phase}' || echo "Unknown")
            : "Latest build: ${latestBuild}"
            : "Build status: ${buildStatus}"

            if [ "${buildStatus}" != "Complete" ]; then
                : "=== Build Details ==="
                oc describe build "${latestBuild}" -n e2e-opp || true
                oc describe buildconfig httpd-example -n e2e-opp || true
            fi
        fi

        : "=== Events ==="
        oc get event -n e2e-opp || true

        : "=== Deployment Status ==="
        oc get deployment -n e2e-opp || true
        oc describe deployment httpd-example -n e2e-opp || true

        : "=== Pod Status ==="
        oc get po -n e2e-opp || true

        : "=== ImageStream Status ==="
        oc get is -n e2e-opp httpd-example -o yaml | grep -A 10 "status:" || true

        : "=== Quay Integration Status ==="
        oc get quayintegration quay -o yaml || true
        oc get cm -n openshift-config opp-ingres-ca -o yaml || true
        oc get secret -n policies quay-integration --no-headers || true

        : "=== Quay Bridge Operator Logs ==="
        typeset operatorPod=""
        operatorPod=$(oc get pod -n openshift-operators -l name=quay-bridge-operator -o jsonpath='{.items[0].metadata.name}' || echo "")
        [ -n "${operatorPod}" ] && oc logs -n openshift-operators "${operatorPod}" -c manager --tail=100 || true

        return 1
    fi

    : "Deployment is available"

    # Collect final status
    oc get build,po,deployment -n e2e-opp || true
    oc get is -n e2e-opp httpd-example -o yaml | grep -A 5 "status:" || true

    return 0
}

################################################################################
# Test Case 2: Test ACS Integration
################################################################################
RunTestCase2() {
    : "====== Test Case 2: Test ACS Integration ======"
    : "NOTE: Waiting for ACS to scan the httpd-example image built in Test Case 1."

    # Fetch ACS credentials - disable xtrace for secret handling
    typeset acsPassword=""
    typeset acsHost=""
    set +x
    acsPassword=$(oc get secret -n stackrox central-htpasswd -o json | /tmp/jq -r '.data.password' | base64 -d)
    acsHost=$(oc get secret -n stackrox sensor-tls -o json | /tmp/jq -r '.data."acs-host"' | base64 -d)
    set -x

    # Query ACS for httpd-example image
    typeset jqFilter='.images[] | select(.name | contains("httpd-example"))'

    typeset -i retries=10
    typeset -i retryInterval=30
    typeset isImageFound=false
    typeset httpdImageJson="" imageId="" cves="" image=""

    : "Waiting for httpd-example image to appear in ACS (max $((retries * retryInterval))s)..."
    typeset attempt=""
    for attempt in $(seq 1 "${retries}"); do
        : "Attempt ${attempt}/${retries}: Querying ACS for httpd-example image..."
        # Disable xtrace to protect ACS password in curl arguments
        set +x
        httpdImageJson=$(curl -s -k -u "admin:${acsPassword}" "https://${acsHost}/v1/images" | /tmp/jq "${jqFilter}")
        set -x
        imageId=$(echo "${httpdImageJson}" | /tmp/jq .id)
        if [ "${imageId}" != "" ]; then
            cves=$(echo "${httpdImageJson}" | /tmp/jq .cves)
            image=$(echo "${httpdImageJson}" | /tmp/jq .name)
            : "Success: Found ${cves} CVEs for image ${image}"
            isImageFound=true
            break
        fi

        [ "${attempt}" -lt "${retries}" ] && sleep "${retryInterval}"
    done

    [ "${isImageFound}" = true ] || return 1

    return 0
}

################################################################################
# Test Execution Setup
################################################################################
# Set trap to generate JUnit XML on exit (regardless of success or failure)
trap GenerateJunitXml EXIT

################################################################################
# Pre-flight Checks
################################################################################
: "====== Pre-flight Check: QuayIntegration ======"

if ! oc get quayintegration quay >/dev/null; then
    : "ERROR: QuayIntegration 'quay' not found!"
    : "OPP bundle components are not properly configured."
    : "Cannot proceed with testing - marking all test cases as failed."

    # Mark all tests as failed with specific message
    for test in "${allTestCasesArr[@]}"; do
        testStatus["${test}"]="failed"
        testFailureMsg["${test}"]="QuayIntegration not found - OPP bundle not configured"
    done

    # Exit immediately (EXIT trap will generate JUnit XML)
    exit 0
fi

: "QuayIntegration quay found"
oc get quayintegration quay -o yaml || true

################################################################################
# Execute Test Cases
################################################################################
# Run Test Case 1
typeset -i case1Start=0
case1Start=$(date +%s)
if RunTestCase1; then
    typeset -i case1Duration=$(( $(date +%s) - case1Start ))
    RecordTestResult "deploy-opp-application" "passed" "" "${case1Duration}"
    : "Test Case 1 (Deploy OPP Application) Result: PASSED"

    # Run Test Case 2 (ACS Integration)
    typeset -i case2Start=0
    case2Start=$(date +%s)
    if RunTestCase2; then
        typeset -i case2Duration=$(( $(date +%s) - case2Start ))
        RecordTestResult "test-acs-integration" "passed" "" "${case2Duration}"
        : "Test Case 2 (Test ACS Integration) Result: PASSED"
    else
        typeset -i case2Duration=$(( $(date +%s) - case2Start ))
        RecordTestResult "test-acs-integration" "failed" "ACS integration test failed" "${case2Duration}"
        : "Test Case 2 (Test ACS Integration) Result: FAILED"
    fi
else
    typeset -i case1Duration=$(( $(date +%s) - case1Start ))
    : "Test Case 1 (Deploy OPP Application) Result: FAILED"
    : "Test Case 1 failed, skipping remaining test cases..."
    RecordTestResult "deploy-opp-application" "failed" "OPP application deployment failed" "${case1Duration}"
    RecordTestResult "test-acs-integration" "skipped" "Skipped: prerequisite Test Case 1 (deploy) failed" "0"
fi

: "====== Test Summary ======"
: "All test results will be available in JUnit XML report"

# Always exit 0 to allow subsequent test steps to run
# Test results are reported via JUnit XML
exit 0
