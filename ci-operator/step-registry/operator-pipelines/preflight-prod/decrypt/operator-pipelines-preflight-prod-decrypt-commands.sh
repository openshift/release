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
    preflight-trigger decode --value ${PFLT_DOCKERCONFIG} | preflight-trigger decrypt \
    --gpg-decryption-private-key ${gpg_private_key_file} \
    --gpg-decryption-public-key ${gpg_public_key_file} \
    --output-path ${SHARED_DIR}/decrypted_config.json

    echo "Artifacts decrypted and accessible"
    exit 0
else
    echo "No artifacts to decrypt"
    exit 0
fi
