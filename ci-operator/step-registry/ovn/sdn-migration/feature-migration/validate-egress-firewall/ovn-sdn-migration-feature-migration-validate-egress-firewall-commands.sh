#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

validate_egressfirewall_cr () {
  kubectl get egressfirewall -n test-migration default -o json | jq .spec | tee current_config
  echo "$EXPECT_EGRESS_FIREWALL_SPEC" | tee expected_config
  if diff <(jq -S . current_config) <(jq -S . expected_config); then
    echo "configuration is migrated as expected"
  else
    echo "configuration is not migrated as expected"
    exit 1
  fi
}

validate_egressnetworkpolicy_cr () {
  kubectl get egressnetworkpolicy -n test-migration default -o json | jq .spec | tee current_config
  echo "$EXPECT_EGRESS_FIREWALL_SPEC" | tee expected_config
  if diff <(jq -S . current_config) <(jq -S . expected_config); then
    echo "configuration is migrated as expected"
  else
    echo "configuration is not migrated as expected"
    exit 1
  fi
}

TMPDIR=$(mktemp -d)
pushd ${TMPDIR}

echo "check the cluster running CNI"
RUNNING_CNI=$(oc get network.operator cluster -o=jsonpath='{.spec.defaultNetwork.type}')

if [[ $RUNNING_CNI == "OpenShiftSDN" ]]; then
  echo "It's an OpenShiftSDN cluster, check the EgressNetworkPolicy CR"
  validate_egressnetworkpolicy_cr
elif [[ $RUNNING_CNI == "OVNKubernetes" ]]; then
  echo "It's an OVNKubernetes cluster, check the EgressFirewall CR"
  validate_egressfirewall_cr
fi
