#!/usr/bin/env bash

# This step will encrypt preflight artifacts.
# https://github.com/redhat-openshift-ecosystem/openshift-preflight

# GPG keys are stored in vault for DPTP and OSD for the hosted pipeline
# Should new keys be generated, the private key 'Real name' MUST be 
# Preflight Trigger and the public key 'Real name' MUST be Operator
# Pipelines; the email address for either key is trivial

gpg_private_key_file=/var/run/operator-pipelines-gpg/private
gpg_public_key_file=/var/run/operator-pipelines-gpg/public
preflight_targz_file="${SHARED_DIR}/preflight.tar.gz"
preflight_targz_file_encrypted="${SHARED_DIR}/preflight.tar.gz.asc"

echo "Encrypting artifacts"
preflight-trigger encrypt \
--gpg-encryption-private-key ${gpg_private_key_file} \
--gpg-encryption-public-key ${gpg_public_key_file} \
--file ${preflight_targz_file} \
--output-path ${preflight_targz_file_encrypted}

echo "Make encrypted artifacts accessible"
mv $preflight_targz_file_encrypted ${ARTIFACT_DIR}

echo "Artifacts encrypted and accessible"
exit 0
