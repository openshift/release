#!/usr/bin/env bash

# This step will decrypt preflight artifacts.
# https://github.com/redhat-openshift-ecosystem/openshift-preflight

# GPG keys are stored in vault for DPTP and OSD for the hosted pipeline
# Should new keys be generated, the private key 'Real name' MUST be 
# Preflight Trigger and the public key 'Real name' MUST be Operator
# Pipelines; the email address for either key is trivial

gpg_private_key_file=/var/run/operator-pipelines-gpg/private
gpg_public_key_file=/var/run/operator-pipelines-gpg/public

export PFLT_DOCKERCONFIG

if [ -n "${PFLT_DOCKERCONFIG}" ]
then
    echo "Import and trust private key"
    gpg -q --import $gpg_private_key_file 1> /dev/null
    echo "`gpg --list-keys|grep -B1 'Preflight Trigger'|awk 'NR==1 { print }'|tr -d '[:space:]'`":6: | gpg --import-ownertrust 1> /dev/null

    echo "Import and trust public key"
    gpg -q --import $gpg_public_key_file 1> /dev/null
    echo "`gpg --list-keys|grep -B1 'Operator Pipelines'|awk 'NR==1 { print }'|tr -d '[:space:]'`":6: | gpg -q --import-ownertrust 1> /dev/null

    echo "Decrypting artifacts"
    echo ${PFLT_DOCKERCONFIG} | basenc -d --base16 | gpg -q --decrypt - 2> /dev/null 1> ${SHARED_DIR}/decrypted_config.json

    echo "Artifacts decrypted and accessible"
    exit 0
else
    echo "No artifacts to decrypt"
    exit 0
fi
