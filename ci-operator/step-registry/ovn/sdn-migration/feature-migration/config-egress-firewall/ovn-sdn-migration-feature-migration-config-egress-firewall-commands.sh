#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

oc create ns test-migration
cat <<EOF | oc apply -f -
apiVersion: network.openshift.io/v1
kind: EgressNetworkPolicy
metadata:
  name: default
  namespace: test-migration
spec:
  egress: []
EOF
PATCH=(\{\"spec\": "$EGRESS_FIREWALL_SPEC"\})
JSON_PATCH=$(echo "${PATCH[@]}")
oc patch egressnetworkpolicy -n test-migration default --type='merge' --patch "${JSON_PATCH}"
