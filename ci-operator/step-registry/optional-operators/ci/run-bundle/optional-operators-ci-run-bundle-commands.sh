#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Deploying an operator in the bundle format using operator-sdk run bundle command"

# `run bundle` supports three install modes: AllNamespaces, OwnNamespace and SingleNamespace.
if [[ "${OO_TARGET_NAMESPACES}" != "AllNamespaces" && "${OO_TARGET_NAMESPACES}" != "OwnNamespace" && "${OO_TARGET_NAMESPACES}" != "SingleNamespace" ]]; then
    echo "install mode should be one of the supported install modes {AllNamespaces, OwnNamespace, SingleNamespace}"
    exit 1
fi

TMPDIR=/tmp
cd $TMPDIR

# handle creation of install namespace if it does not exist
if [[ "$OO_INSTALL_NAMESPACE" == "create" ]]; then
    echo "OO_INSTALL_NAMESPACE is 'create': creating new namespace"
    oc create namespace "$OO_INSTALL_NAMESPACE"
elif ! oc get namespace "$OO_INSTALL_NAMESPACE"; then
    echo "OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE' which does not exist: creating"
    oc create namespace "$OO_INSTALL_NAMESPACE"
else
    echo "OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE'"
fi

# create the operator bundle using `run bundle` command.
operator-sdk run bundle "${OO_BUNDLE_IMG}" \
                        --index-image "${OO_INDEX_IMG}" \
                        --namespace "${OO_INSTALL_NAMESPACE}" \
                        --install-mode "${OO_TARGET_NAMESPACES}"

# create artifacts directory to collect all the manifests in yaml format.
ARTIFACT_DIR=$TMPDIR/artifacts
mkdir $ARTIFACT_DIR && cd $ARTIFACT_DIR

POD_ART="$ARTIFACT_DIR/registrypod.yaml"
echo "Logging Registry pod as $POD_ART"
oc get -n "$OO_INSTALL_NAMESPACE" pod -o yaml >"$POD_ART"

CS_ART="$ARTIFACT_DIR/catsrc.yaml"
echo "Logging CatalogSource as $CS_ART"
oc get -n "$OO_INSTALL_NAMESPACE" catalogsource -o yaml >"$CS_ART"

SUB_ART="$ARTIFACT_DIR/subscription.yaml"
echo "Logging Subscription as $SUB_ART"
oc get -n "$OO_INSTALL_NAMESPACE" subscription -o yaml >"$SUB_ART"

OG_ART="$ARTIFACT_DIR/og.yaml"
echo "Logging OperatorGroup as $OG_ART"
oc get -n "$OO_INSTALL_NAMESPACE" operatorgroup -o yaml >"$OG_ART"

IP_ART="$ARTIFACT_DIR/ip.yaml"
echo "Logging InstallPlan as $IP_ART"
oc get -n "$OO_INSTALL_NAMESPACE" installplan -o yaml >"$IP_ART"

CSV_ART="$ARTIFACT_DIR/csv.yaml"
echo "Logging ClusterServiceVersion as $CSV_ART"
oc get -n "$OO_INSTALL_NAMESPACE" csv -o yaml >"$CSV_ART"

