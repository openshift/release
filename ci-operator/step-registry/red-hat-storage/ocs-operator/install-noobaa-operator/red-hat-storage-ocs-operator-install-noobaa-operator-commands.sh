#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ocs-catalog
  namespace: openshift-marketplace
spec:
  displayName: OCS Catalog
  image: quay.io/nigoyal/odf-operator-catalog:latest
  publisher: Red Hat
  sourceType: grpc
EOF

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
EOF

OPERATORGROUP=$(oc -n openshift-storage get operatorgroup -o jsonpath="{.items[*].metadata.name}" || true)
if [[ -n "$OPERATORGROUP" ]]; then
    echo "OperatorGroup \"$OPERATORGROUP\" exists: modifying it"
    OG_NAMESTANZA="name: $OPERATORGROUP"
else
    echo "OperatorGroup does not exist: creating it"
    OG_NAMESTANZA="name: ocs-operatorgroup"
fi

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  $OG_NAMESTANZA
  namespace: openshift-storage
spec:
  targetNamespaces: [openshift-storage]
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: noobaa-operator
  namespace: openshift-storage
spec:
  installPlanApproval: Automatic
  name: noobaa-operator
  source: ocs-catalog
  sourceNamespace: openshift-marketplace
EOF

for _ in {1..60}; do
    CSV=$(oc -n openshift-storage get subscription noobaa-operator -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n openshift-storage get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" is ready"
            exit 0
        fi
    fi
    sleep 10
done

echo "Timed out waiting for CSV to become ready"
exit 1
