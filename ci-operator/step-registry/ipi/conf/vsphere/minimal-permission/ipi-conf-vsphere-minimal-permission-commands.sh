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

# shellcheck disable=SC2153
ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)
if [ "${ocp_minor_version}" -lt 13 ]; then
cat > "${PATCH}" << EOF
platform:
  vsphere:
    username: "${vcenter_username_minimal_permission}"
    password: "${vcenter_password_minimal_permission}"
EOF
else
cat > "${PATCH}" << EOF
platform:
  vsphere:
    vcenters:
    - user: "${vcenter_username_minimal_permission}"
      password: "${vcenter_password_minimal_permission}"
EOF
fi
yq-go m -x -i "${CONFIG}" "${PATCH}"
