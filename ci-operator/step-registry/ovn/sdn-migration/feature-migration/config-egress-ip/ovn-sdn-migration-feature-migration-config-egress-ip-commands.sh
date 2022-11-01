#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

# First get a hostsubnet corresponding to a worker node and netnamespace
HOSTSUBNET_NAME=$(oc get hostsubnets -o=jsonpath='{.items[3].host}')
NETNAMESPACE_NAME="test-migration"

# Namespace may or may not be created already, creating just in case.
oc create ns $NETNAMESPACE_NAME || true

# Get egressCIDR value from node's egress-ipconfig field.
# egress_ipconfig=$(oc get node $HOSTSUBNET_NAME -o json | jq .metadata.annotations.'"cloud.network.openshift.io/egress-ipconfig"')
# egress_ipconfig_parsed=${egress_ipconfig##*ipv4\":\"}
# egress_cidrs=${egress_ipconfig_parsed%%\"*}

# Define patch value
# hsn_patch='{"egressCIDRs": ["'
# hsn_patch+=$egress_cidrs
# hsn_patch+='"]}'

# In future we may refine above query to dynamically get egressCIDRs.
# egress-ipconfig field for nodes is hardcoded in cluster config so using hardcoded value is acceptable.
hsn_patch='{"egressCIDRs": ["10.0.128.0/18"]}'

# Patch the resources to contain egress config.
oc patch hostsubnet "$HOSTSUBNET_NAME" --type=merge -p   "$hsn_patch"
oc patch netnamespace $NETNAMESPACE_NAME --type=merge -p   '{"egressIPs": ["10.0.128.5"]}'