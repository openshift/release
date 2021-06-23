#!/bin/bash

# Steps for extracting and applying the kube_secrets ISV parameter
# Expects the standard Prow environment variables to be set

REHEARSAL_INSTALL_NAMESPACE="!create"

PYXIS_URL="${PYXIS_URL:-""}"
# The namespace into which the operator and catalog will be
# installed. Special value `!create` means that a new namespace will be created.
INSTALL_NAMESPACE="${INSTALL_NAMESPACE:-$REHEARSAL_INSTALL_NAMESPACE}"

# Check if PYXIS_URL exists, skip the whole step if not.
if [[ -z "$PYXIS_URL" ]]; then
    echo "PYXIS_URL is not defined, skipping step cvp-common-apply-secrets!"
    exit 0
else
    echo "PYXIS_URL is defined, proceeding with cvp-common-apply-secrets step."
fi

echo "Creating a new NAMESPACE"
if [[ "$INSTALL_NAMESPACE" == "!create" ]]; then
    echo "INSTALL_NAMESPACE is '!create': creating new namespace"
    NS_NAMESTANZA="generateName: oo-"
elif ! oc get namespace "$INSTALL_NAMESPACE"; then
    echo "INSTALL_NAMESPACE is '$INSTALL_NAMESPACE' which does not exist: creating"
    NS_NAMESTANZA="name: $INSTALL_NAMESPACE"
else
    echo "INSTALL_NAMESPACE is '$INSTALL_NAMESPACE'"
fi

if [[ -n "${NS_NAMESTANZA:-}" ]]; then
    INSTALL_NAMESPACE=$(
        oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  $NS_NAMESTANZA
EOF
    )
fi

# Creating file that contains namespace name
echo "$INSTALL_NAMESPACE" > "${SHARED_DIR}"/operator-install-namespace.txt

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
oc apply -f /tmp/kube_objects.yaml -n "$INSTALL_NAMESPACE"

# Remove the kube objects file just in case
rm -rf /tmp/kube_objects.yaml
