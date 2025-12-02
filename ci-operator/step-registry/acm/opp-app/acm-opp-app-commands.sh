#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

#
# Deploy a sample application on the OPP clusters
#

# cd to writable directory
cd /tmp/

echo "Downloading jq..."
if ! curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/jq; then
    echo "ERROR: Failed to download jq"
    exit 1
fi
chmod +x /tmp/jq

# Verify jq is working
if ! /tmp/jq --version >/dev/null 2>&1; then
    echo "ERROR: jq download succeeded but binary is not executable"
    exit 1
fi
echo "jq installed successfully"

git clone https://github.com/stolostron/policy-collection.git
cd policy-collection/deploy/

echo 'y' | ./deploy.sh -p httpd-example -n policies -u https://github.com/tanfengshuang/grc-demo.git -a e2e-opp
sleep 60

# Patch the placement for the opp example app build
#oc patch -n policies placement placement-policy-build-example-httpd --type=json '-p=[{"op": "replace", "path": "/spec/predicates", "value": [{"requiredClusterSelector":{"labelSelector":{"matchExpressions":[{"key": "name", "operator": "In", "values": ["local-cluster"]}]}}}]}]'
# Using a label for this now instead
oc label managedcluster local-cluster oppapps=httpd-example --overwrite

# Check the status
oc get policies -n policies | grep example || true
oc get build -n e2e-opp
oc get po -n e2e-opp
oc get deployment -n e2e-opp

LATEST_BUILD_NAME=$(oc get builds -n e2e-opp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
BUILD_STATUS=$(oc get build "$LATEST_BUILD_NAME" -n e2e-opp -o jsonpath='{.status.phase}' 2>/dev/null)

echo "Initial build status: ${LATEST_BUILD_NAME} is ${BUILD_STATUS}"

# Wait for the build to complete (max 10 minutes)
echo "Waiting for build ${LATEST_BUILD_NAME} to complete..."
BUILD_TIMEOUT=600  # 10 minutes
BUILD_ELAPSED=0
BUILD_CHECK_INTERVAL=15

while [ $BUILD_ELAPSED -lt $BUILD_TIMEOUT ]; do
    BUILD_STATUS=$(oc get build "$LATEST_BUILD_NAME" -n e2e-opp -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "Build status at ${BUILD_ELAPSED}s: ${BUILD_STATUS}"

    if [ "$BUILD_STATUS" == "Complete" ]; then
        echo "Build ${LATEST_BUILD_NAME} completed successfully"
        break
    elif [ "$BUILD_STATUS" == "Failed" ] || [ "$BUILD_STATUS" == "Error" ] || [ "$BUILD_STATUS" == "Cancelled" ]; then
        echo "!!! Build ${LATEST_BUILD_NAME} failed with status: ${BUILD_STATUS}"

        # Check the error info
        oc get event -n e2e-opp
        oc describe buildconfig httpd-example -n e2e-opp
        oc describe build "$LATEST_BUILD_NAME" -n e2e-opp
        
        echo "=== Quay Bridge Operator Logs ==="
        OPERATOR_POD_NAME=$(oc get pod -n openshift-operators -l name=quay-bridge-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        oc logs $OPERATOR_POD_NAME -n openshift-operators -c manager --tail=50 || true

        echo "!!! Starting a new build..."
        LATEST_BUILD_NAME=$(oc start-build httpd-example -n e2e-opp -o name | cut -d'/' -f2)
        echo "New build started: ${LATEST_BUILD_NAME}"
        BUILD_ELAPSED=0  # Reset timer for new build
        continue
    fi

    sleep $BUILD_CHECK_INTERVAL
    BUILD_ELAPSED=$((BUILD_ELAPSED + BUILD_CHECK_INTERVAL))
done

# Final check
BUILD_STATUS=$(oc get build "$LATEST_BUILD_NAME" -n e2e-opp -o jsonpath='{.status.phase}' 2>/dev/null)
if [ "$BUILD_STATUS" != "Complete" ]; then
    echo "!!! ERROR: Build did not complete within ${BUILD_TIMEOUT}s. Final status: ${BUILD_STATUS}"
    oc get build "$LATEST_BUILD_NAME" -n e2e-opp -o yaml
    exit 1
fi

# Wait for the deployment to be ready
echo "Waiting for deployment to be available..."
oc wait --for=condition=Available deployment/httpd-example -n e2e-opp --timeout=5m

# Check the info after the application deployed successfully
oc get policies -n policies | grep example || true
oc get build -n e2e-opp
oc get po -n e2e-opp
oc get deployment -n e2e-opp
oc get cm -n openshift-config opp-ingres-ca -o yaml
oc get quayintegration quay -o yaml
oc get secret -n policies quay-integration -o yaml


# Run other tests

# Obtain details about the test application from ACS
echo "=== Testing ACS Integration ==="
echo "Fetching ACS credentials..."
ACS_PASSWORD=$(oc get secret -n stackrox central-htpasswd -o json 2>/dev/null | /tmp/jq -r '.data.password' | base64 -d)
if [ -z "$ACS_PASSWORD" ]; then
    echo "ERROR: Failed to retrieve ACS password"
    exit 1
fi

ACS_HOST=$(oc get secret -n stackrox sensor-tls -o json 2>/dev/null | /tmp/jq -r '.data."acs-host"' | base64 -d)
if [ -z "$ACS_HOST" ]; then
    echo "ERROR: Failed to retrieve ACS host"
    exit 1
fi
echo "ACS Host: ${ACS_HOST}"

JQ_FILTER='.images[] | select(.name | contains("httpd-example"))'
ACS_COMMAND="curl -s -k -u admin:${ACS_PASSWORD} https://$ACS_HOST/v1/images"

RETRIES=10
RETRY_INTERVAL=30
echo "Waiting for httpd-example image to appear in ACS (max $((RETRIES * RETRY_INTERVAL))s)..."

for attempt in $(seq 1 $RETRIES); do
    echo "Attempt $attempt/$RETRIES: Querying ACS for httpd-example image..."

    # Query ACS API and check for valid response
    ACS_RESPONSE=$($ACS_COMMAND 2>&1)

    # Check if response is empty or contains error
    if [ -z "$ACS_RESPONSE" ]; then
        echo "WARNING: ACS API returned empty response"
        if [ $attempt -eq $RETRIES ]; then
            echo "ERROR: ACS API unreachable after $RETRIES attempts"
            exit 1
        fi
    # Check if response contains JSON array (valid API response starts with {)
    elif echo "$ACS_RESPONSE" | grep -q '^{'; then
        HTTPD_IMAGE_JSON=$(echo "$ACS_RESPONSE" | /tmp/jq "$JQ_FILTER" 2>/dev/null)
        ID=$(echo "$HTTPD_IMAGE_JSON" | /tmp/jq -r '.id' 2>/dev/null)

        if [ -n "$ID" ] && [ "$ID" != "null" ]; then
            CVES=$(echo "$HTTPD_IMAGE_JSON" | /tmp/jq '.cves')
            IMAGE_NAME=$(echo "$HTTPD_IMAGE_JSON" | /tmp/jq -r '.name')
            echo "✓ Success: Found $CVES CVEs for image $IMAGE_NAME"
            echo "Image ID: $ID"
            exit 0
        else
            echo "Image not found in ACS response yet"
        fi
    else
        echo "WARNING: ACS API call failed with: ${ACS_RESPONSE:0:200}"
        if [ $attempt -eq $RETRIES ]; then
            echo "ERROR: ACS API unreachable after $RETRIES attempts"
            exit 1
        fi
    fi

    if [ $attempt -lt $RETRIES ]; then
        echo "Waiting ${RETRY_INTERVAL}s before retry..."
        sleep $RETRY_INTERVAL
    fi
done

echo "ERROR: httpd-example image not found in ACS after $((RETRIES * RETRY_INTERVAL))s"
echo "This may indicate an issue with ACS integration or image scanning"
exit 1
