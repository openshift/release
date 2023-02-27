#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

config_sdn_egressip_crs() {
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
}

config_egressip_cr() {
  oc label node --overwrite $HOSTSUBNET_NAME k8s.ovn.org/egress-assignable=
  cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egressip-test-migration
spec:
  egressIPs:
  - "10.0.128.5"
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: "test-migration"
EOF
}

TMPDIR=$(mktemp -d)
pushd ${TMPDIR}

echo "check the cluster running CNI"
RUNNING_CNI=$(oc get network.operator cluster -o=jsonpath='{.spec.defaultNetwork.type}')

# First get a hostsubnet corresponding to a worker node and netnamespace
HOSTSUBNET_NAME=$(oc get nodes --selector="node-role.kubernetes.io/worker" -o jsonpath='{.items[0].metadata.name}')
NETNAMESPACE_NAME="test-migration"

# Namespace may or may not be created already, creating just in case.
oc create ns $NETNAMESPACE_NAME || true

if [[ $RUNNING_CNI == "OpenShiftSDN" ]]; then
  echo "It's an OpenShiftSDN cluster, config the HostSubnet and Netnamespace CRs"
  config_sdn_egressip_crs
elif [[ $RUNNING_CNI == "OVNKubernetes" ]]; then
  echo "It's an OVNKubernetes cluster, create a EgressIP CR"
  config_egressip_cr
fi