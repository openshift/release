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

RELEASE_IMAGE_INSTALL="${RELEASE_IMAGE_INITIAL:-}"
if [[ -z "${RELEASE_IMAGE_INSTALL}" ]]; then
  # If there is no initial release, we will be installing latest.
  RELEASE_IMAGE_INSTALL="${RELEASE_IMAGE_LATEST:-}"
fi
cp "${CLUSTER_PROFILE_DIR}"/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret "${RELEASE_IMAGE_INSTALL}" -ojsonpath='{.metadata.version}' | cut -d. -f 1,2)
ocp_minor_version=$(echo "${ocp_version}" | awk --field-separator=. '{print $2}')
rm /tmp/pull-secret

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
