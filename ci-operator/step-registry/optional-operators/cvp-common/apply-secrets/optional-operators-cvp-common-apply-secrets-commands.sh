#!/bin/bash

# Steps for extracting and applying the kube_objects
# Expects the standard Prow environment variables to be set

REHEARSAL_INSTALL_NAMESPACE="!create"
# The namespace into which the operator and catalog will be
# installed. Special value `!create` means that a new namespace will be created.
OO_INSTALL_NAMESPACE="${OO_INSTALL_NAMESPACE:-$REHEARSAL_INSTALL_NAMESPACE}"
KUBE_OBJECTS_LOCATION="/var/run/kube-objects-${OO_PACKAGE}/kube_objects"

# Check if PYXIS_URL exists, skip the whole step if not.
if [[ ! -f "${KUBE_OBJECTS_LOCATION}" ]]; then
    echo "The custom kube_objects are not defined, skipping step cvp-common-apply-secrets!"
    exit 0
else
    echo "The custom kube_objects are defined, proceeding with cvp-common-apply-secrets step."
fi

echo "Creating a new NAMESPACE"
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

# Creating file that contains namespace name
echo "$OO_INSTALL_NAMESPACE" > "${SHARED_DIR}"/operator-install-namespace.txt

echo "Applying the kube_objects on the testing OCP cluster"
oc apply -f "${KUBE_OBJECTS_LOCATION}" -n "${OO_INSTALL_NAMESPACE}"

# TODO Remove after confirming POC
oc get sa -n "${OO_INSTALL_NAMESPACE}"
