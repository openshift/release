#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

config_egress_network_policy_cr() {
cat <<EOF | oc apply -f -
apiVersion: network.openshift.io/v1
kind: EgressNetworkPolicy
metadata:
  name: default
  namespace: test-migration
spec:
  egress: []
EOF
  oc patch egressnetworkpolicy -n test-migration default --type='merge' --patch "${JSON_PATCH}"
}

config_egress_firewall_cr() {
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressFirewall
metadata:
  name: default
  namespace: test-migration
spec:
  egress: []
EOF
  oc patch egressfirewalls -n test-migration default --type='merge' --patch "${JSON_PATCH}"
}

TMPDIR=$(mktemp -d)
pushd ${TMPDIR}

echo "check the cluster running CNI"
RUNNING_CNI=$(oc get network.operator cluster -o=jsonpath='{.spec.defaultNetwork.type}')

PATCH=(\{\"spec\": "$EGRESS_FIREWALL_SPEC"\})
JSON_PATCH=$(echo "${PATCH[@]}")
oc create ns test-migration

if [[ $RUNNING_CNI == "OpenShiftSDN" ]]; then
  echo "It's an OpenShiftSDN cluster, create a EgressNetworkPolicy CR"
  config_egress_network_policy_cr
elif [[ $RUNNING_CNI == "OVNKubernetes" ]]; then
  echo "It's an OVNKubernetes cluster, create a EgressFirewall CR"
  config_egress_firewall_cr
fi