#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

YAML_CONFIG="${SHARED_DIR}/install-config.yaml"

JSON_CONFIG="${SHARED_DIR}/install-config.json"

UPDATED_JSON_CONFIG="${SHARED_DIR}/updated-config.json"

yq-go r "${YAML_CONFIG}" -j > "${JSON_CONFIG}"

jq --arg COMPUTE_DISK_TYPE "$COMPUTE_DISK_TYPE" \
    --arg COMPUTE_NODE_TYPE "$COMPUTE_NODE_TYPE" \
    '.compute[].platform.gcp.gcp.osDisk.diskType = $COMPUTE_DISK_TYPE |
    .compute[].platform.gcp.type = $COMPUTE_NODE_TYPE' "${JSON_CONFIG}" > "${UPDATED_JSON_CONFIG}"

yq-go r --prettyPrint "${UPDATED_JSON_CONFIG}" > "${YAML_CONFIG}"

rm "${UPDATED_JSON_CONFIG}" "${JSON_CONFIG}"
