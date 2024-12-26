#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"

#Deploy Quay Operator to OCP namespace '${QUAYNAMESPACE}'
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${QUAYNAMESPACE}
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: quay
  namespace: ${QUAYNAMESPACE}
spec:
  targetNamespaces:
  - ${QUAYNAMESPACE}
EOF

SUB=$(
    cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: ${QUAYNAMESPACE}
spec:
  installPlanApproval: Automatic
  name: quay-operator
  channel: $QUAY_OPERATOR_CHANNEL
  source: $QUAY_OPERATOR_SOURCE
  sourceNamespace: openshift-marketplace
EOF
)

echo "The Quay Operator subscription is $SUB"

for _ in {1..60}; do
    CSV=$(oc -n ${QUAYNAMESPACE} get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n ${QUAYNAMESPACE} get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "Quay ClusterServiceVersion \"$CSV\" is ready"
            break
        fi
    fi
    sleep 10
done
echo "Quay Operator is deployed successfully"

