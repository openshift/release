#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

payload_url="${RELEASE_IMAGE_LATEST}"

if [[ "$payload_url" == *"@sha256"* ]]; then
    payload_url=$(echo "$payload_url" | sed 's/@sha256.*/:latest/')
fi

echo "Setting runtime dir"
mkdir -p /tmp/.docker/ ${XDG_RUNTIME_DIR}

echo "copy creds"
cp /tmp/import-secret/.dockerconfigjson /tmp/.docker/config.json

echo "Login to registry"
oc registry login --to /tmp/.docker/config.json

echo "Testing auth"
oc adm release info "${payload_url}"

./check-payload scan payload -V "${MAJOR_MINOR}" --url "${payload_url}"
