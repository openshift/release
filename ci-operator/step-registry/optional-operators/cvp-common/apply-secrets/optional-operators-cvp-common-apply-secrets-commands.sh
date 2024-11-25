#!/bin/bash

# Steps for extracting and applying the kube_secrets ISV parameter
# Expects the standard Prow environment variables to be set

REHEARSAL_INSTALL_NAMESPACE="!create"

# The namespace into which the operator and catalog will be
# installed. Special value `!create` means that a new namespace will be created.
OO_INSTALL_NAMESPACE="${OO_INSTALL_NAMESPACE:-$REHEARSAL_INSTALL_NAMESPACE}"
OO_PACKAGE="${OO_PACKAGE:-"cpaas-test-operator-bundle"}"

echo "[$(date --utc +%FT%T.%3NZ)] Creating a new NAMESPACE"
if [[ "$OO_INSTALL_NAMESPACE" == "!create" ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] OO_INSTALL_NAMESPACE is '!create': creating new namespace"
    NS_NAMESTANZA="generateName: oo-"
elif ! oc get namespace "$OO_INSTALL_NAMESPACE"; then
    echo "[$(date --utc +%FT%T.%3NZ)] OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE' which does not exist: creating"
    NS_NAMESTANZA="name: $OO_INSTALL_NAMESPACE"
else
    echo "[$(date --utc +%FT%T.%3NZ)] OO_INSTALL_NAMESPACE is '$OO_INSTALL_NAMESPACE'"
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

# applying custom kubeobjects from the vault configured

KEYWORD_CUSTOM_KUBEOBJECTS="custom-"
CUSTOM_KUBEOBJECTS_PATH="${CUSTOM_KUBEOBJECTS_PATH:=/var/run/}"

# the following command lists all the kubeobjects mounted on CUSTOM_KUBEOBJECTS_PATH 
# with prefix "custom-" and also package name within the name of the file.

echo "[$(date --utc +%FT%T.%3NZ)] The following variables are being used:"
echo "[$(date --utc +%FT%T.%3NZ)] custom kubeobjects path: ${CUSTOM_KUBEOBJECTS_PATH}"
echo "[$(date --utc +%FT%T.%3NZ)] keyword_custom_kubeobjects: ${KEYWORD_CUSTOM_KUBEOBJECTS}"
echo "[$(date --utc +%FT%T.%3NZ)] The OO_package : ${OO_PACKAGE}"

CUSTOM_KUBEOBJECTS_PATH="${CUSTOM_KUBEOBJECTS_PATH}${KEYWORD_CUSTOM_KUBEOBJECTS}${OO_PACKAGE}"

# check if the directory exists or not in first place 
# if not send message and gracefully exit.

if [ ! -d "${CUSTOM_KUBEOBJECTS_PATH}" ]
then
    echo "[$(date --utc +%FT%T.%3NZ)] Directory ${CUSTOM_KUBEOBJECTS_PATH} DOES NOT exists."
    echo "[$(date --utc +%FT%T.%3NZ)] Please check the vault"
    echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution Successfully !"
    exit 0 
fi

echo "CUSTOM_KUBEOBJECTS_PATH found: $CUSTOM_KUBEOBJECTS_PATH"
echo "Looking for kube_objects inside path"
LIST_OF_KUBEOBJECTS=$(find "${CUSTOM_KUBEOBJECTS_PATH}"* -type f -name kube_objects)
# checks if we found any custom kube objects in the respective paths
if [ -n "${LIST_OF_KUBEOBJECTS[0]}" ] ; then
    for i in "${LIST_OF_KUBEOBJECTS[@]}"
    do
	echo "[$(date --utc +%FT%T.%3NZ)] The following custom kubeobject has been found ! $i"
	echo "[$(date --utc +%FT%T.%3NZ)]  Check if the namespace is mentioned inside the kubeobjects"
        if oc apply -f "$i" --dry-run=client | grep  "^namespace/"
        then
            echo "[$(date --utc +%FT%T.%3NZ)] Namespace found in kubeobjects. Applying directly"
	    oc apply -f "$i"
        else
            echo "[$(date --utc +%FT%T.%3NZ)] Applying kube_objects on to the Namespace $OO_INSTALL_NAMESPACE"
            oc apply -f "$i" -n "$OO_INSTALL_NAMESPACE"
        fi	
    done
else
    echo "[$(date --utc +%FT%T.%3NZ)] Could not find any kubeobjects please check the vault"
fi
