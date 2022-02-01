#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

OO_INSTALL_NAMESPACE=openshift-operators

SUB=$(
    cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: $OO_INSTALL_NAMESPACE
spec:
  installPlanApproval: Automatic
  name: quay-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
)

for _ in {1..60}; do
    CSV=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n "$OO_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"
            exit 0
        fi
    fi
    STATUS=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription quay-operator -o jsonpath='{.status.conditions[?(@.type=="InstallPlanFailed")].status}' || true)
    if [[ "$STATUS" == "True" ]]; then
        MESSAGE=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription quay-operator -o jsonpath='{range .status.conditions[?(@.type=="InstallPlanFailed")]}{.type}{" ("}{.reason}{"): "}{.message}{end}')
        echo "quay-operator: $MESSAGE"
        exit 1
    fi
    sleep 10
done
echo "Timed out waiting for CSV to become ready"
exit 1
