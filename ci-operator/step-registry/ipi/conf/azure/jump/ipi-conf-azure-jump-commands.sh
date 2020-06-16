#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/install-config.yaml"

azure_region=$(/tmp/yq r ${CONFIG} 'platform.azure.region')

jump=""
case "${azure_region}" in
centralus) jump="core@13.89.227.20";;
westus) jump="core@40.83.209.79";;
eastus) jump="core@52.152.225.95";;
eastus2) jump="core@52.254.78.33";;
*) echo >&2 "invalid region index"; exit 1;;
esac
echo "Jump host : ${jump}"

echo "${jump}" > "${SHARED_DIR}"/jump-host.txt
