#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

echo "$(date -u --rfc-3339=seconds) - Import Image"
pc_url="https://${prism_central_host}:${prism_central_port}"
un="${prism_central_username}"
pw="${prism_central_password}"

coreos_location=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.nutanix.formats.qcow2.disk.location')
coreos_release=$(openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.nutanix.release')
preload_image_name=qe-preload-$coreos_release-${UNIQUE_HASH}.qcow2

api_ep="${pc_url}/api/nutanix/v3/images"
data="{
  \"spec\": {
    \"name\": \"$preload_image_name\",
    \"resources\": {
      \"image_type\": \"DISK_IMAGE\",
      \"source_uri\": \"$coreos_location\"
    }
  },
  \"metadata\": {
    \"kind\": \"image\"
  }
}"
import_image_json=$(curl -ks -u "${un}":"${pw}" -X POST "${api_ep}" -H "Content-Type: application/json" -d @-<<<"${data}")

task_uuid=$(echo "${import_image_json}" | jq -r ".status.execution_context.task_uuid")
image_uuid=$(echo "${import_image_json}" | jq -r ".metadata.uuid")

api_ep="${pc_url}/api/nutanix/v3/tasks/$task_uuid"
loops=0
max_loops=10
sleep_seconds=60
while true
do
  task_json=$(curl -ks -u "${un}":"${pw}" -X GET "${api_ep}" -H "Content-Type: application/json")
  task_status=$(echo "${task_json}" | jq -r ".status")
  if [[ "$task_status" == "SUCCEEDED" ]]; then
    echo "Image preload succeeded"
    # preserve image uuid to delete
    echo "$image_uuid" > "${SHARED_DIR}/preload-image-delete.txt"
    echo "$preload_image_name" > "${SHARED_DIR}/preload-image-name.txt"
    break
  fi
  if [[ "$loops" -ge "$max_loops" ]]; then
    echo "Timeout, failed to preload image"
    exit 1
  fi
  echo "Image preload is not succeeded yet, wait $sleep_seconds seconds"
  loops=("$loops"+1)
  sleep $sleep_seconds
done

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/install-config-patch-preloadedOSImageName.yaml"

cat >"${PATCH}" <<EOF
platform:
  nutanix:
    preloadedOSImageName: $preload_image_name
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "Updated preloadedOSImageName in '${CONFIG}'."

echo "The updated preloadedOSImageName:"
yq-go r "${CONFIG}" platform.nutanix.preloadedOSImageName
