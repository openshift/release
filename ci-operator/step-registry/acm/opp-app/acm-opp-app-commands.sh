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

curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 > /tmp/jq
chmod +x /tmp/jq

git clone https://github.com/stolostron/policy-collection.git
cd policy-collection/deploy/

echo 'y' | ./deploy.sh -p httpd-example -n policies -u https://github.com/tanfengshuang/grc-demo.git -a e2e-opp

# Wait for the Quay resources to be created
# How do I check this?

sleep 60

# Patch the placement for the opp example app build
#oc patch -n policies placement placement-policy-build-example-httpd --type=json '-p=[{"op": "replace", "path": "/spec/predicates", "value": [{"requiredClusterSelector":{"labelSelector":{"matchExpressions":[{"key": "name", "operator": "In", "values": ["local-cluster"]}]}}}]}]'
# Using a label for this now instead
oc label managedcluster local-cluster oppapps=httpd-example

# Check the status
oc get policies -n policies | grep example
oc get build -n e2e-opp
oc get po -n e2e-opp
oc get deployment -n e2e-opp

LATEST_BUILD_NAME=$(oc get builds -n e2e-opp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
BUILD_STATUS=$(oc get build "$LATEST_BUILD_NAME" -n e2e-opp -o jsonpath='{.status.phase}' 2>/dev/null)

if [ "$BUILD_STATUS" == "Failed" ]; then
    # Check the error info
    oc get event -n e2e-opp
    oc describe buildconfig httpd-example -n e2e-opp
    OPERATOR_POD_NAME=$(oc get pod -n openshift-operators -l name=quay-bridge-operator -o jsonpath='{.items[0].metadata.name}')
    oc logs $OPERATOR_POD_NAME -n openshift-operators -c manager --tail=20

    echo "!!! Build ${LATEST_BUILD_NAME} failed. Starting a new Build..."
    oc start-build httpd-example -n e2e-opp
fi

# Wait for the deployment to be ready
oc wait --for=condition=Available deployment/httpd-example -n e2e-opp --timeout=10m

# Check some other info after the application deployed successfully
oc get cm -n openshift-config opp-ingres-ca -o yaml
oc get quayintegration quay -o yaml
oc get secret -n policies quay-integration -o yaml


# Run other tests

# Obtain details about the test application from ACS
ACS_PASSWORD=`oc get secret -n stackrox central-htpasswd -o json | /tmp/jq .data.password | sed 's/"//g' | base64 -d`
JQ_FILTER='.images[] | select(.name | contains("httpd-example"))'
ACS_HOST=`oc get secret -n stackrox sensor-tls -o json | /tmp/jq '.data."acs-host"' | sed 's/"//g' | base64 -d`
ACS_COMMAND="curl -s -k -u "admin:${ACS_PASSWORD}" https://$ACS_HOST/v1/images"

set +e
x=1
RETRIES=10
while [ $x -lt $RETRIES ]; do
    HTTPD_IMAGE_JSON=`$ACS_COMMAND | /tmp/jq "$JQ_FILTER"`
    ID=`echo "$HTTPD_IMAGE_JSON" | /tmp/jq .id`
    if [ "$ID" != "" ]; then
        CVES=`echo "$HTTPD_IMAGE_JSON" | /tmp/jq .cves`
        image=`echo "$HTTPD_IMAGE_JSON" | /tmp/jq .name`
        echo "Found $CVES CVEs for image $image"
        break
    fi

    let x=$x+1

    # Check if this is the final attempt (x is about to exceed the limit)
    if [ $x -eq $RETRIES ]; then
        echo "ERROR: Image ID not found after $((RETRIES - 1)) attempts. Exiting with failure."
        exit 1
    fi

    echo "Try $x/$((RETRIES - 1)): ID not found. Checking again in 30 seconds."
    sleep 30
done
set -e
