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

echo "Import and trust private key"
gpg -q --import $gpg_private_key_file 1> /dev/null
echo "`gpg --list-keys|grep -B1 'Preflight Trigger'|awk 'NR==1 { print }'|tr -d '[:space:]'`":6: | gpg --import-ownertrust 1> /dev/null

echo "Import and trust public key"
gpg -q --import $gpg_public_key_file 1> /dev/null
echo "`gpg --list-keys|grep -B1 'Operator Pipelines'|awk 'NR==1 { print }'|tr -d '[:space:]'`":6: | gpg -q --import-ownertrust 1> /dev/null

echo "Sign the public key"
gpg -q --batch --yes --sign-key "`gpg --list-keys|grep -B1 'Operator Pipelines'|awk 'NR==1 { print }'|tr -d '[:space:]'`" 1> /dev/null

echo "Encrypting artifacts"
gpg -q --encrypt --sign --armor -r "`gpg --list-keys|grep -B1 'Operator Pipelines'|awk 'NR==1 { print }'|tr -d '[:space:]'`" $preflight_targz_file 1> /dev/null

echo "Make encrypted artifacts accessible"
mv $preflight_targz_file_encrypted ${ARTIFACT_DIR}

echo "Artifacts encrypted and accessible"
exit 0
