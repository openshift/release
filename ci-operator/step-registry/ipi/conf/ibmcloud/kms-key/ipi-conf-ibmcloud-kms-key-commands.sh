#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

cat "${SHARED_DIR}/ibm_kpKey.yaml"

yq-go m -x -i "${CONFIG}" "${SHARED_DIR}/ibm_kpKey.yaml"

cat "${CONFIG}"


