#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CLUSTER_PROFILE_NAME:-}" != "vsphere-elastic" ]]; then
  echo "using legacy sibling of this step"
  exit 0
fi

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_extra_leased_context"

declare -a vips
mapfile -t vips < "${SHARED_DIR}"/vips.txt

# if loadbalancer is UserManaged, it's mean using external LB,
# then keepalived and haproxy will not deployed, but coredns still keep
if [[ ${LB_TYPE} == "UserManaged" ]]; then
    APIVIPS_DEF="apiVIPs:
      - ${vips[0]}"
    INGRESSVIPS_DEF="ingressVIPs:
      - ${vips[1]}"
    LB_TYPE_DEF="loadBalancer:
      type: UserManaged"
else
    APIVIPS_DEF=""
    INGRESSVIPS_DEF=""
    LB_TYPE_DEF=""
fi

# CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/multisubnets.yaml.patch"

cat >"${PATCH}" <<EOF
platform:
  vsphere:
    ${LB_TYPE_DEF}
    ${APIVIPS_DEF}
    ${INGRESSVIPS_DEF}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
