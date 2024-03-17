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

echo 'y' | ./deploy.sh -p httpd-example -n policies -u https://github.com/gparvin/grc-demo.git -a e2e-opp

# Wait for the Quay resources to be created
# How do I check this?

sleep 60

# Patch the placement for the opp example app build
#oc patch -n policies placement placement-policy-build-example-httpd --type=json '-p=[{"op": "replace", "path": "/spec/predicates", "value": [{"requiredClusterSelector":{"labelSelector":{"matchExpressions":[{"key": "name", "operator": "In", "values": ["local-cluster"]}]}}}]}]'
# Using a label for this now instead
oc label managedcluster local-cluster oppapps=httpd-example

sleep 60

# check to see if the application deployed successfully

oc get po -n e2e-opp
echo ""
oc get deployment -n e2e-opp
echo ""
oc get event -n e2e-opp
echo ""
oc get cm -n openshift-config opp-ingres-ca -o yaml
echo ""
oc get quayintegration quay -o yaml
echo ""
oc get secret -n policies quay-integration -o yaml

# run other tests

# Obtain details about the test application from ACS
ACS_PASSWORD=`oc get secret -n stackrox central-htpasswd -o json | /tmp/jq .data.password | sed 's/"//g' | base64 -d`
JQ_FILTER='.images[] | select(.name | contains("httpd-example"))'
ACS_HOST=`oc get secret -n stackrox sensor-tls -o json | /tmp/jq '.data."acs-host"' | sed 's/"//g' | base64 -d`
ACS_COMMAND="curl -k -u "admin:${ACS_PASSWORD}" https://$ACS_HOST/v1/images"
x=1
while [ $x -lt 10 ]; do
	HTTPD_IMAGE_JSON=`$ACS_COMMAND | /tmp/jq "$JQ_FILTER"`
	ID=`echo "$HTTPD_IMAGE_JSON" | /tmp/jq .id`
	if [ "$ID" != "" ]; then
		CVES=`echo "$HTTPD_IMAGE_JSON" | /tmp/jq .cves`
		image=`echo "$HTTPD_IMAGE_JSON" | /tmp/jq .name`
		echo "Found $CVES CVEs for image $image"
		break
	fi
	let x=$x+1
	sleep 30
done

