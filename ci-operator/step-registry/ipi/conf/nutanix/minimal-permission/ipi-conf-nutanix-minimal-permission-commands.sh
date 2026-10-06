#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

declare prism_central_username_minimal_permission
declare prism_central_password_minimal_permission

NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh

# shellcheck source=/dev/null
source "${NUTANIX_AUTH_PATH}"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/permission-user.yaml.patch"

cat > "${PATCH}" << EOF
platform:
  nutanix:
    prismCentral:
      username: "${prism_central_username_minimal_permission}"
      password: "${prism_central_password_minimal_permission}"
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
