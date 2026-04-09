#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

#
# Make a record of the version of the operators (OPP Products) that are tested.
#

curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 > /tmp/jq
chmod +x /tmp/jq

# Display product name and version for each OPP product installed in interop test
OCP=`oc version -o json | /tmp/jq .openshiftVersion | sed 's/"//g'`
ACM=`oc get csv -n ocm -l operators.coreos.com/advanced-cluster-management.ocm="" -o json | /tmp/jq '.items[0].spec.version' | sed 's/"//g'`
QUAY=`oc get csv -n local-quay -l operators.coreos.com/quay-operator.local-quay="" -o json | /tmp/jq '.items[0].spec.version' | sed 's/"//g'`
ACS=`oc get csv -n rhacs-operator -l operators.coreos.com/rhacs-operator.rhacs-operator="" -o json | /tmp/jq '.items[0].spec.version' | sed 's/"//g'`
ODF=`oc get csv -n openshift-storage -l operators.coreos.com/odf-operator.openshift-storage="" -o json | /tmp/jq '.items[0].spec.version' | sed 's/"//g'`

set +x
echo "# OpenShift Platform Plus products tested"
echo "## Product Versions"
echo "Product Tested | Version Tested"
echo "---- | ----"
echo "OpenShift | $OCP"
echo "ACM | $ACM"
echo "Quay | $QUAY"
echo "ODF | $ODF"
echo "ACS | $ACS"

echo ""
echo "## Managed Clusters"
echo "Name | OpenShift Version"
echo "---- | ----"
for name in `oc get managedcluster -o custom-columns=:.metadata.name`; do
	version=`oc get managedcluster local-cluster -o custom-columns=:.metadata.labels.openshiftVersion | grep -v '^$'`
	echo "$name | $version"
done
