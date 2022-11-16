#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

validate_egressip_cr () {
  current_config_unformatted=$(kubectl get egressip -n test-migration egressip-test-migration -o json | jq .spec)
  current_config="$(echo -e "${current_config_unformatted}" | tr -d '[:space:]')"
  if diff <(echo "$current_config") <(echo "$EXPECT_EGRESS_IP_SPEC"); then
    echo "configuration is migrated as expected"
  else
    echo "configuration is not migrated as expected"
    exit 1
  fi
}

validate_sdn_egressip_crs () {
  HOSTSUBNET_NAME=$(oc get nodes --selector="node-role.kubernetes.io/worker" -o jsonpath='{.items[0].metadata.name}')
  NETNAMESPACE_NAME="test-migration"

  kubectl get hostsubnet -n test-migration $HOSTSUBNET_NAME -o json | jq .egressCIDRs | tee current_egressCIDRs
  kubectl get hostsubnet -n test-migration $HOSTSUBNET_NAME -o json | jq .egressIPs | tee current_hsn_egressIPs
  kubectl get netnamespace -n test-migration $NETNAMESPACE_NAME -o json | jq .egressIPs | tee current_nns_egressIPs

  echo "$EXPECT_HOSTSUBNET_EGRESS_CIDRS" | tee expected_egressCIDRs
  echo "$EXPECT_HOSTSUBNET_EGRESS_IPS" | tee expected_hsn_egressIPs
  echo "$EXPECT_NETNAMESPACE_EGRESS_IPS" | tee expected_nns_egressIPs

  if diff <(jq -S . current_egressCIDRs) <(jq -S . expected_egressCIDRs); then
    echo "egressCIDR is migrated as expected"
  else
    echo "egressCIDR is not migrated as expected"
    exit 1
  fi

  if diff <(jq -S . current_hsn_egressIPs) <(jq -S . expected_hsn_egressIPs); then
    echo "hostsubnet egressIP is migrated as expected"
  else
    echo "hostsubnet egressIP is not migrated as expected"
    exit 1
  fi

  if diff <(jq -S . current_nns_egressIPs) <(jq -S . expected_nns_egressIPs); then
    echo "netnamespace egressIP is migrated as expected"
  else
    echo "netnamespace egressIP is not migrated as expected"
    exit 1
  fi
}

TMPDIR=$(mktemp -d)
pushd ${TMPDIR}

echo "check the cluster running CNI"
RUNNING_CNI=$(oc get network.operator cluster -o=jsonpath='{.spec.defaultNetwork.type}')

if [[ $RUNNING_CNI == "OpenShiftSDN" ]]; then
  echo "It's an OpenShiftSDN cluster, check the HostSubnet and Netnamespace CRs"
  validate_sdn_egressip_crs
elif [[ $RUNNING_CNI == "OVNKubernetes" ]]; then
  echo "It's an OVNKubernetes cluster, check the EgressIP CR"
  validate_egressip_cr
fi