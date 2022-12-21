#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CNV_INSTALL_NAMESPACE=openshift-cnv
CNV_OPERATOR_CHANNEL="$CNV_OPERATOR_CHANNEL"


echo "Installing CNV from ${CNV_OPERATOR_CHANNEL} into ${CNV_INSTALL_NAMESPACE}"

# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${CNV_INSTALL_NAMESPACE}"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${CNV_INSTALL_NAMESPACE}-operator-group"
  namespace: "${CNV_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - $(echo \"${CNV_INSTALL_NAMESPACE}\" | sed "s|,|\"\n  - \"|g")
EOF

# subscribe to the operator
SUB=$(
    cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: $CNV_INSTALL_NAMESPACE
spec:
  channel: $CNV_OPERATOR_CHANNEL
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
)

for _ in {1..60}; do
    CSV=$(oc -n "$CNV_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n "$CNV_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"
            break
        fi
    fi
    sleep 10
done

oc create -f - <<EOF
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
EOF

oc wait hyperconverged -n openshift-cnv kubevirt-hyperconverged --for=condition=Available --timeout=15m

echo "CNV is deployed successfully"
