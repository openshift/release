#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

OLM_VER_WHOLE="$CALICO_OLM_VERSION"
OLM_VER_CHANNEL="$CALICO_OLM_CHANNEL"
echo "Adding Tigera Operator Group"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: tigera-operator
  namespace: tigera-operator
spec:
  targetNamespaces:
    - tigera-operator
EOF


echo "Adding Tigera Operator Subscription"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: tigera-operator
  namespace: tigera-operator
spec:
  channel: release-v${OLM_VER_CHANNEL}
  installPlanApproval: Manual
  name: tigera-operator
  source: certified-operators
  sourceNamespace: openshift-marketplace
  startingCSV: tigera-operator.v${OLM_VER_WHOLE}
EOF

install_plan_name=$(oc get installplan -n tigera-operator -o=jsonpath='{items[0].metadata.name}')
oc patch installplan $install_plan_name --namespace tigera-operator --type merge --patch '{"spec":{"approved":true}}'

