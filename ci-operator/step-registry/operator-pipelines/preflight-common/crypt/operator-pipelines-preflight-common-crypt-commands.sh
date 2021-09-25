#!/usr/bin/env bash

# This step will encrypt preflight artifacts.
# https://github.com/redhat-openshift-ecosystem/openshift-preflight

gpg_private_key_file=/var/run/operator-pipelines-gpg/private
gpg_public_key_file=/var/run/operator-pipelines-gpg/public
preflight_targz_file="${SHARED_DIR}/preflight.tar.gz"
preflight_targz_file_encrypted="${SHARED_DIR}/preflight.tar.gz.asc"

echo "Importing and signing keys"

gpg -q --import $gpg_private_key_file
gpg -q --import $gpg_public_key_file
gpg -q --pinentry-mode loopback --batch --yes --sign-key mhillsma@redhat.com

echo "Encrypting artifacts"

gpg -q --pinentry-mode loopback --encrypt --batch --yes --sign --armor --trust-model always -r opdevemail@gmail.com $preflight_targz_file
mv $preflight_targz_file_encrypted ${ARTIFACT_DIR}

echo "Artifact encryption completed"
exit 0
