#!/bin/bash

# Steps for extracting and applying the kube_secrets ISV parameter
# Expects the standard Prow environment variables to be set

REHEARSAL_INSTALL_NAMESPACE="!create"

PYXIS_URL="${PYXIS_URL:-""}"
# The namespace into which the operator and catalog will be
# installed. Special value `!create` means that a new namespace will be created.
OO_INSTALL_NAMESPACE="${OO_INSTALL_NAMESPACE:-$REHEARSAL_INSTALL_NAMESPACE}"

# Check if PYXIS_URL exists, skip the whole step if not.
if [[ -z "$PYXIS_URL" ]]; then
    echo "PYXIS_URL is not defined, skipping step cvp-common-apply-secrets!"
    exit 0
else
    echo "PYXIS_URL is defined, proceeding with cvp-common-apply-secrets step."
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

GPG_KEY='/var/run/cvp-pyxis-gpg-secret/cvp-gpg.key' # Secret file which will be mounted by DPTP
GPG_PASS='/var/run/cvp-pyxis-gpg-secret/cvp-gpg.pass' # Secret file which will be mounted by DPTP
PKCS12_CERT='/var/run/cvp-pyxis-gpg-secret/cvp-dptp.cert' # Secret file which will be mounted by DPTP
PKCS12_KEY='/var/run/cvp-pyxis-gpg-secret/cvp-dptp.key' # Secret file which will be mounted by DPTP

echo "Fetching the kube_objects from Pyxis for ISV pid ${PYXIS_URL}"
touch /tmp/get_kubeObjects.txt
curl --key "${PKCS12_KEY}" --cert "${PKCS12_CERT}" "${PYXIS_URL}" | jq -r ".container.kube_objects" > /tmp/get_kubeObjects.txt

echo "Decrypting the kube_objects fetched from Pyxis"
gpg --batch --yes --quiet --pinentry-mode loopback --import --passphrase-file "${GPG_PASS}" "${GPG_KEY}"
gpg --batch --yes --quiet --pinentry-mode loopback --decrypt --passphrase-file "${GPG_PASS}" /tmp/get_kubeObjects.txt > /tmp/kube_objects.yaml

echo "Applying the kube_objects on the testing OCP cluster"
oc apply -f /tmp/kube_objects.yaml -n "$OO_INSTALL_NAMESPACE"

# Remove the kube objects file just in case
rm -rf /tmp/kube_objects.yaml


KEYWORD_CUSTOM_KUBEOBJECTS="custom-"

CUSTOM_KUBEOBJECTS_PATH=${CUSTOM_KUBEOBJECTS_PATH:=/var/run/}

# the following command lists all the kubeobjects mounted on CUSTOM_KUBEOBJECTS_PATH 
# with prefix "custom-" and also package name within the name of the file.

LIST_OF_KUBEOBJECTS=$(find "${CUSTOM_KUBEOBJECTS_PATH}${KEYWORD_CUSTOM_KUBEOBJECTS}${OO_PACKAGE}"* -type f -name kube_objects)

for i in "${LIST_OF_KUBEOBJECTS[@]}"
do
    echo "The following custom kubeobject has been found ! $i"
    oc apply -f "$CUSTOM_KUBEOBJECTS_PATH$i" -n "$OO_INSTALL_NAMESPACE"
done
