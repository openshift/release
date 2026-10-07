#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

image_uuid="$(cat "${SHARED_DIR}/preload-image-delete.txt")"

if [[ -f ${CLUSTER_PROFILE_DIR}/secrets.sh ]]; then
  NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh
else
  NUTANIX_AUTH_PATH=/var/run/vault/nutanix/secrets.sh
fi
declare prism_central_host
declare prism_central_port
declare prism_central_username
declare prism_central_password
# shellcheck source=/dev/null
source "${NUTANIX_AUTH_PATH}"

echo "$(date -u --rfc-3339=seconds) - Delete Image"
pc_url="https://${prism_central_host}:${prism_central_port}"
un="${prism_central_username}"
pw="${prism_central_password}"

api_ep="${pc_url}/api/nutanix/v3/images/$image_uuid"
curl -ks -u "${un}":"${pw}" -X DELETE "${api_ep}" -H "Content-Type: application/json"

echo "$(date -u --rfc-3339=seconds) - Delete successful."
