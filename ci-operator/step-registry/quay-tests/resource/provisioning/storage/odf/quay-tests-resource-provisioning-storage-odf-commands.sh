#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Deploy ODF Operator to OCP namespace 'openshift-storage'
OO_INSTALL_NAMESPACE=openshift-storage
ODF_OPERATOR_CHANNEL="$ODF_OPERATOR_CHANNEL"
ODF_SUBSCRIPTION_NAME="$ODF_SUBSCRIPTION_NAME"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
EOF

OPERATORGROUP=$(oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup -o jsonpath="{.items[*].metadata.name}" || true)
if [[ -n "$OPERATORGROUP" ]]; then
  echo "OperatorGroup \"$OPERATORGROUP\" exists: modifying it"
  OG_OPERATION=apply
  OG_NAMESTANZA="name: $OPERATORGROUP"
else
  echo "OperatorGroup does not exist: creating it"
  OG_OPERATION=create
  OG_NAMESTANZA="generateName: oo-"
fi

OPERATORGROUP=$(
  oc $OG_OPERATION -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  $OG_NAMESTANZA
  namespace: $OO_INSTALL_NAMESPACE
spec:
  targetNamespaces: [$OO_INSTALL_NAMESPACE]
EOF
)

SUB=$(
  cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $ODF_SUBSCRIPTION_NAME
  namespace: $OO_INSTALL_NAMESPACE
spec:
  channel: $ODF_OPERATOR_CHANNEL
  installPlanApproval: Automatic
  name: $ODF_SUBSCRIPTION_NAME
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
)

for i in {1..60}; do
  CSV=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
  if [[ -n "$CSV" ]]; then
    if [[ "$(oc -n "$OO_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
      echo "ODF ClusterServiceVersion \"$CSV\" ready"
      break
    fi
  fi
  echo "wait $((i*10))s"
  sleep 10
done
echo "ODF/OCS Operator is deployed successfully"

#Wait for odf operator pod startup
for i in {1..60}; do
  PStatus=$(oc -n "$OO_INSTALL_NAMESPACE" get pod -l name=ocs-operator -o jsonpath='{..status.conditions[?(@.type=="Ready")].status}' || true)
  if [[ "$PStatus" == "True" ]]; then
      echo "ODF pod is running \"$PStatus\""
      break
  fi
  podstatus=$(oc -n "$OO_INSTALL_NAMESPACE" get pod) 
  echo "odf pod status $podstatus"
  echo "wait $((i*10))s"
  sleep 10
done

sleep 100 # Wait for all ODF service to be ready

cat <<EOF | oc apply -f -
apiVersion: noobaa.io/v1alpha1
kind: NooBaa
metadata:
  name: noobaa
  namespace: openshift-storage
spec:
  dbResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
  coreResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
  dbType: postgres
EOF

echo "Waiting for NooBaa Storage to be ready..." >&2
oc -n openshift-storage wait noobaa.noobaa.io/noobaa --for=condition=Available --timeout=240s || true
