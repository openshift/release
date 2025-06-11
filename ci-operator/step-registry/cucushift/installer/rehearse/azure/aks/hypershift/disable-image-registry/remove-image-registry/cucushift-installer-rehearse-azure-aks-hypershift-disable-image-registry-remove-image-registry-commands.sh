#!/bin/bash
set -exuo pipefail

if [[ $USE_HYPERSHIFT_AZURE_CREDS == "true" ]]; then
   jq 'del(.imageRegistry)' /etc/hypershift-ci-jobs-azurecreds/managed-identities.json $SHARED_DIR/managed-identities-del-image-registry.json
else
   jq 'del(.imageRegistry)' /etc/hypershift-aro-azurecreds/managed-identities.json $SHARED_DIR/managed-identities-del-image-registry.json
fi