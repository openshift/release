#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# if loadbalancer is UserManaged, it's mean using external LB,
# then keepalived and haproxy will not deployed, but coredns still keep
if [[ ${LB_TYPE} == "UserManaged" ]]; then
  declare -a vips
  mapfile -t vips <"${SHARED_DIR}"/vips.txt
  APIVIPS_DEF="apiVIPs:
      - ${vips[0]}"
  INGRESSVIPS_DEF="ingressVIPs:
      - ${vips[1]}"
  LB_TYPE_DEF="loadBalancer:
      type: UserManaged"

  CONFIG="${SHARED_DIR}/install-config.yaml"
  PATCH="${SHARED_DIR}/multisubnets.yaml.patch"

  cat >"${PATCH}" <<EOF
platform:
  vsphere:
    ${LB_TYPE_DEF}
    ${APIVIPS_DEF}
    ${INGRESSVIPS_DEF}
EOF

  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi
