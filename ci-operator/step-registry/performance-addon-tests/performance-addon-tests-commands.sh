#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

PAO_INSTALL_NAMESPACE=performance-addon-operator


echo "Installing PAO from ${PAO_OPERATOR_CHANNEL} into ${PAO_INSTALL_NAMESPACE}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${PAO_INSTALL_NAMESPACE}"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${PAO_INSTALL_NAMESPACE}-operator-group"
  namespace: "${PAO_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${PAO_INSTALL_NAMESPACE}\" | sed "s|,|\"\n  - \"|g")
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: performance-addon-operator-subscription
  namespace: "${PAO_INSTALL_NAMESPACE}"
spec:
  channel: stable
  name: performace-addon-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

sleep 1800