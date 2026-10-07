#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

validate_egressip_cr () {
  current_config_unformatted=$(kubectl get egressip -n test-migration egressip-test-migration -o json | jq .spec)
  current_config="$(echo -e "${current_config_unformatted}" | tr -d '[:space:]')"
  egressIP_node=$(kubectl get egressip -n test-migration egressip-test-migration -o jsonpath='{.status.items[*].node}')
  expected_egressCIDRs=$(oc get no  "$egressIP_node" -o jsonpath="{.metadata.annotations.cloud\.network\.openshift\.io/egress-ipconfig}" | jq -r '.[].ifaddr.ipv4')
  ip_part=$(echo "$expected_egressCIDRs" | cut -d'/' -f1)
  expected_egressIP="${ip_part%.*}.5"
  expected_config="{\"egressIPs\":[\"$expected_egressIP\"],\"namespaceSelector\":{\"matchLabels\":{\"kubernetes.io/metadata.name\":\"test-migration\"}}}"
  if diff <(echo "$current_config") <(echo "$expected_config"); then
    echo "configuration is migrated as expected"
  else
    echo "configuration is not migrated as expected"
    exit 1
  fi
}

validate_sdn_egressip_crs () {
  HOSTSUBNET_NAME=$(oc get nodes --selector="node-role.kubernetes.io/worker" -o jsonpath='{.items[0].metadata.name}')
  NETNAMESPACE_NAME="test-migration"

  kubectl get hostsubnet $HOSTSUBNET_NAME -o json | jq .egressCIDRs | tee current_egressCIDRs
  kubectl get hostsubnet $HOSTSUBNET_NAME -o json | jq .egressIPs | tee current_hsn_egressIPs
  kubectl get netnamespace $NETNAMESPACE_NAME -o json | jq .egressIPs | tee current_nns_egressIPs

  expected_egressCIDRs=$(oc get no  "$HOSTSUBNET_NAME" -o jsonpath="{.metadata.annotations.cloud\.network\.openshift\.io/egress-ipconfig}" | jq -r '.[].ifaddr.ipv4')
  ip_part=$(echo "$expected_egressCIDRs" | cut -d'/' -f1)
  expected_egressIPs="[\"${ip_part%.*}.5\"]"
  expected_egressCIDRs="[\"$expected_egressCIDRs\"]"

  if diff <(jq -S . current_egressCIDRs) <(jq -S . <<< "$expected_egressCIDRs"); then
    echo "egressCIDR is migrated as expected"
  else
    echo "egressCIDR is not migrated as expected"
    exit 1
  fi

  if diff <(jq -S . current_hsn_egressIPs) <(jq -S . <<< "$expected_egressIPs"); then
    echo "hostsubnet egressIP is migrated as expected"
  else
    echo "hostsubnet egressIP is not migrated as expected"
    exit 1
  fi

  if diff <(jq -S . current_nns_egressIPs) <(jq -S . <<< "$expected_egressIPs"); then
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
  kubectl patch netnamespace $NETNAMESPACE_NAME --type=merge -p '{"egressIPs": []}'
elif [[ $RUNNING_CNI == "OVNKubernetes" ]]; then
  echo "It's an OVNKubernetes cluster, check the EgressIP CR"
  validate_egressip_cr
  kubectl delete egressip -n test-migration egressip-test-migration
fi