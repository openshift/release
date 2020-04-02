#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# The pullspec of an index image. Required.
OO_INDEX="$OO_INDEX"

# The name of the operator package to be installed. Must be present in
# the index image referenced by $OO_INDEX. Required.
OO_PACKAGE="$OO_PACKAGE"

# The name of the operator channel to track. Required.
OO_CHANNEL="$OO_CHANNEL"

# The namespace into which the operator and catalog will be
# installed. If empty, a new namespace will be created.
OO_INSTALL_NAMESPACE="${OO_INSTALL_NAMESPACE:-}"

# A comma-separated list of namespaces the operator will target. If
# empty, all namespaces will be targeted.  If no OperatorGroup exists
# in $OO_INSTALL_NAMESPACE, a new one will be created with its target
# namespaces set to $OO_TARGET_NAMESPACES, otherwise the existing
# OperatorGroup's target namespace set will be replaced. The special
# value "!install" will set the target namespace to the operator's
# installation namespace.
OO_TARGET_NAMESPACES="${OO_TARGET_NAMESPACES:-}"

if [[ -z "$OO_INSTALL_NAMESPACE" ]]; then
    OO_INSTALL_NAMESPACE=$(
        oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  generateName: oo-
EOF
    )
else
    oc get namespace "$OO_INSTALL_NAMESPACE"
fi

echo "installing \"$OO_PACKAGE\" in namespace \"$OO_INSTALL_NAMESPACE\""

if [[ "$OO_TARGET_NAMESPACES" == "!install" ]]; then
    echo "targeting operator installation namespace"
    OO_TARGET_NAMESPACES="$OO_INSTALL_NAMESPACE"
fi

OPERATORGROUP=$(oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup -o jsonpath="{.items[*].metadata.name}" || true)
if [[ $(echo "$OPERATORGROUP" | wc -w) -gt 1 ]]; then
    echo "error: multiple operatorgroups in namespace \"$OO_INSTALL_NAMESPACE\": $OPERATORGROUP" 1>&2
    exit 1
fi

OPERATORGROUP=$(
    oc "$([[ -n "$OPERATORGROUP" ]] && printf apply || printf create)" -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  $([[ -n "$OPERATORGROUP" ]] && echo "name: $OPERATORGROUP" || echo "generateName: oo-")
  namespace: $OO_INSTALL_NAMESPACE
spec:
  targetNamespaces: [$OO_TARGET_NAMESPACES]
EOF
)

echo "operator group name is \"$OPERATORGROUP\""

CATSRC=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  generateName: oo-
  namespace: $OO_INSTALL_NAMESPACE
spec:
  sourceType: grpc
  image: "$OO_INDEX"
EOF
)

echo "catalog source name is \"$CATSRC\""

SUB=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  generateName: oo-
  namespace: $OO_INSTALL_NAMESPACE
spec:
  name: $OO_PACKAGE
  channel: $OO_CHANNEL
  source: $CATSRC
  sourceNamespace: $OO_INSTALL_NAMESPACE
EOF
)

echo "subscription name is \"$SUB\""
echo "waiting for csv to become ready..."

for _ in $(seq 1 30); do
    CSV=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n "$OO_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "csv \"$CSV\" ready"
            exit 0
        fi
    fi
    sleep 10
done

echo "timed out waiting for csv to become ready" 1>&2
oc get namespace "$OO_INSTALL_NAMESPACE" -o yaml 1>&2
oc get -n "$OO_INSTALL_NAMESPACE" operatorgroup "$OPERATORGROUP" -o yaml 1>&2
oc get -n "$OO_INSTALL_NAMESPACE" catalogsource "$CATSRC" -o yaml 1>&2
oc get -n "$OO_INSTALL_NAMESPACE" subscription "$SUB" -o yaml 1>&2
if [[ -n "$CSV" ]]; then
    oc get -n "$OO_INSTALL_NAMESPACE" csv "$CSV" -o yaml 1>&2
else
    oc get -n "$OO_INSTALL_NAMESPACE" csv -o yaml 1>&2
fi
exit 1
