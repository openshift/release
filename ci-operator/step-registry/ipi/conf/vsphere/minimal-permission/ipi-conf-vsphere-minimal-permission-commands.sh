#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

declare vcenter_username_minimal_permission
declare vcenter_password_minimal_permission

VCENTER_AUTH_PATH=/var/run/vault/devqe-secrets/secrets.sh
# shellcheck source=/dev/null
source "${VCENTER_AUTH_PATH}"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/permission-user.yaml.patch"

cat > "${PATCH}" << EOF
platform:
  vsphere:
    username: "${vcenter_username_minimal_permission}"
    password: "${vcenter_password_minimal_permission}"
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
