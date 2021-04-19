#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# These values serve as defaults when the parameters are not set, which should
# only happen in rehearsals. Production jobs should always set the OO_* variables.
REHEARSAL_INDEX="brew.registry.redhat.io/rh-osbs-stage/iib:23576"
REHEARSAL_PACKAGE="e2e-test-operator"
REHEARSAL_CHANNEL="4.3"
REHEARSAL_INSTALL_NAMESPACE="!create"
REHEARSAL_TARGET_NAMESPACES="!install"

# The pullspec of an index image. Required.
OO_INDEX="${OO_INDEX:-$REHEARSAL_INDEX}"

# The name of the operator package to be installed. Must be present in
# the index image referenced by $OO_INDEX. Required.
OO_PACKAGE="${OO_PACKAGE:-$REHEARSAL_PACKAGE}"

# The name of the operator channel to track. Required.
OO_CHANNEL="${OO_CHANNEL:-$REHEARSAL_CHANNEL}"

# The namespace into which the operator and catalog will be
# installed. Special value `!create` means that a new namespace will be created.
OO_INSTALL_NAMESPACE="${OO_INSTALL_NAMESPACE:-$REHEARSAL_INSTALL_NAMESPACE}"

# A comma-separated list of namespaces the operator will target. Special, value
# `!all` means that all namespaces will be targeted. If no OperatorGroup exists
# in $OO_INSTALL_NAMESPACE, a new one will be created with its target namespaces
# set to $OO_TARGET_NAMESPACES, otherwise the existing OperatorGroup's target
# namespace set will be replaced. The special value "!install" will set the
# target namespace to the operator's installation namespace.

OO_TARGET_NAMESPACES="${OO_TARGET_NAMESPACES:-$REHEARSAL_TARGET_NAMESPACES}"

if [[ "$OO_INSTALL_NAMESPACE" == "!create" ]]; then
    echo "OO_INSTALL_NAMESPACE is '!create': creating new namespace"
    NS_NAMESTANZA="generateName: oo-"
elif ! oc get namespace "$OO_INSTALL_NAMESPACE"; then
    echo "OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE' which does not exist: creating"
    NS_NAMESTANZA="name: $OO_INSTALL_NAMESPACE"
else
    echo "OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE'"
fi

if [[ -n "${NS_NAMESTANZA:-}" ]]; then
    OO_INSTALL_NAMESPACE=$(
        oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  $NS_NAMESTANZA
EOF
    )
fi

echo "Installing \"$OO_PACKAGE\" in namespace \"$OO_INSTALL_NAMESPACE\""

if [[ "$OO_TARGET_NAMESPACES" == "!install" ]]; then
    echo "OO_TARGET_NAMESPACES is '!install': targeting operator installation namespace ($OO_INSTALL_NAMESPACE)"
    OO_TARGET_NAMESPACES="$OO_INSTALL_NAMESPACE"
elif [[ "$OO_TARGET_NAMESPACES" == "!all" ]]; then
    echo "OO_TARGET_NAMESPACES is '!all': all namespaces will be targeted"
    OO_TARGET_NAMESPACES=""
fi

OPERATORGROUP=$(oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup -o jsonpath="{.items[*].metadata.name}" || true)

if [[ $(echo "$OPERATORGROUP" | wc -w) -gt 1 ]]; then
    echo "Error: multiple OperatorGroups in namespace \"$OO_INSTALL_NAMESPACE\": $OPERATORGROUP" 1>&2
    oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup -o yaml >"$ARTIFACT_DIR/operatorgroups-$OO_INSTALL_NAMESPACE.yaml"
    exit 1
elif [[ -n "$OPERATORGROUP" ]]; then
    echo "OperatorGroup \"$OPERATORGROUP\" exists: modifying it"
    oc -n "$OO_INSTALL_NAMESPACE" get operatorgroup "$OPERATORGROUP" -o yaml >"$ARTIFACT_DIR/og-$OPERATORGROUP-orig.yaml"
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
  targetNamespaces: [$OO_TARGET_NAMESPACES]
EOF
)

echo "OperatorGroup name is \"$OPERATORGROUP\""
echo "Creating CatalogSource"

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

echo "CatalogSource name is \"$CATSRC\""

DEPLOYMENT_START_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "Set the deployment start time: ${DEPLOYMENT_START_TIME}"

echo "Creating Subscription"

SUB=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  generateName: oo-
  namespace: $OO_INSTALL_NAMESPACE
spec:
  name: $OO_PACKAGE
  channel: "$OO_CHANNEL"
  source: $CATSRC
  sourceNamespace: $OO_INSTALL_NAMESPACE
EOF
)

echo "Subscription name is \"$SUB\""
echo "Waiting for ClusterServiceVersion to become ready..."

for _ in $(seq 1 60); do
    CSV=$(oc -n "$OO_INSTALL_NAMESPACE" get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n "$OO_INSTALL_NAMESPACE" get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"

            DEPLOYMENT_ART="oo_deployment_details.yaml"
            echo "Saving deployment details in ${DEPLOYMENT_ART} as a shared artifact"
            cat > "${ARTIFACT_DIR}/${DEPLOYMENT_ART}" <<EOF
---
csv: "${CSV}"
operatorgroup: "${OPERATORGROUP}"
subscription: "{SUB}"
catalogsource: "${CATSRC}"
install_namespace: "${OO_INSTALL_NAMESPACE}"
target_namespaces: "${OO_TARGET_NAMESPACES}"
deployment_start_time: "${DEPLOYMENT_START_TIME}"
EOF
            cp "${ARTIFACT_DIR}/${DEPLOYMENT_ART}" "${SHARED_DIR}/${DEPLOYMENT_ART}"
            exit 0
        fi
    fi
    sleep 10
done

echo "Timed out waiting for csv to become ready"

NS_ART="$ARTIFACT_DIR/ns-$OO_INSTALL_NAMESPACE.yaml"
echo "Dumping Namespace $OO_INSTALL_NAMESPACE as $NS_ART"
oc get namespace "$OO_INSTALL_NAMESPACE" -o yaml >"$NS_ART"

OG_ART="$ARTIFACT_DIR/og-$OPERATORGROUP.yaml"
echo "Dumping OperatorGroup $OPERATORGROUP as $OG_ART"
oc get -n "$OO_INSTALL_NAMESPACE" operatorgroup "$OPERATORGROUP" -o yaml >"$OG_ART"

CS_ART="$ARTIFACT_DIR/cs-$CATSRC.yaml"
echo "Dumping CatalogSource $CATSRC as $CS_ART"
oc get -n "$OO_INSTALL_NAMESPACE" catalogsource "$CATSRC" -o yaml >"$CS_ART"
for field in message reason; do
    VALUE="$(oc get -n "$OO_INSTALL_NAMESPACE" catalogsource "$CATSRC" -o jsonpath="{.status.$field}" || true)"
    if [[ -n "$VALUE" ]]; then
        echo "  CatalogSource $CATSRC status $field: $VALUE"
    fi
done

SUB_ART="$ARTIFACT_DIR/sub-$SUB.yaml"
echo "Dumping Subscription $SUB as $SUB_ART"
oc get -n "$OO_INSTALL_NAMESPACE" subscription "$SUB" -o yaml >"$SUB_ART"
for field in state reason; do
    VALUE="$(oc get -n "$OO_INSTALL_NAMESPACE" subscription "$SUB" -o jsonpath="{.status.$field}" || true)"
    if [[ -n "$VALUE" ]]; then
        echo "  Subscription $SUB status $field: $VALUE"
    fi
done

if [[ -n "$CSV" ]]; then
    CSV_ART="$ARTIFACT_DIR/csv-$CSV.yaml"
    echo "ClusterServiceVersion $CSV was created but never became ready"
    echo "Dumping ClusterServiceVersion $CSV as $CSV_ART"
    oc get -n "$OO_INSTALL_NAMESPACE" csv "$CSV" -o yaml >"$CSV_ART"
    for field in phase message reason; do
        VALUE="$(oc get -n "$OO_INSTALL_NAMESPACE" csv "$CSV" -o jsonpath="{.status.$field}" || true)"
        if [[ -n "$VALUE" ]]; then
            echo "  ClusterServiceVersion $CSV status $field: $VALUE"
        fi
    done
else
    CSV_ART="$ARTIFACT_DIR/$OO_INSTALL_NAMESPACE-all-csvs.yaml"
    echo "ClusterServiceVersion was never created"
    echo "Dumping all ClusterServiceVersions in namespace $OO_INSTALL_NAMESPACE to $CSV_ART"
    oc get -n "$OO_INSTALL_NAMESPACE" csv -o yaml >"$CSV_ART"
fi
exit 1
