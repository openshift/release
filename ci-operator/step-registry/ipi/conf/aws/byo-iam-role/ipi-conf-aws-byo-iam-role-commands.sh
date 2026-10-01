#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=$(mktemp)

if [[ "${ENABLE_BYO_IAM_ROLE_DEFAULT_MACHINE}" == "true" ]]; then
  cat >"${PATCH}" <<EOF
platform:
  aws:
    defaultMachinePlatform:
      iamRole: $(head -n 1 ${SHARED_DIR}/aws_byo_role_name_master)
EOF
  echo "Patching defaultMachinePlatform:"
  cat $PATCH
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

if [[ "${ENABLE_BYO_IAM_ROLE_CUMPUTE}" == "true" ]]; then
  cat >"${PATCH}" <<EOF
compute:
- platform:
    aws:
      iamRole: $(head -n 1 ${SHARED_DIR}/aws_byo_role_name_worker)
EOF
  echo "Patching compute node:"
  cat $PATCH
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

if [[ "${ENABLE_BYO_IAM_ROLE_CONTROL_PLANE}" == "true" ]]; then
  cat >"${PATCH}" <<EOF
controlPlane:
  platform:
    aws:
      iamRole: $(head -n 1 ${SHARED_DIR}/aws_byo_role_name_master)
EOF
  echo "Patching control plane node:"
  cat $PATCH
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

# The edge compute pool is a named entry (compute[name=edge]), so it cannot be
# targeted by the index-based merge above; select it by name with yq-v4 instead.
if [[ "${ENABLE_BYO_IAM_ROLE_EDGE}" == "true" ]]; then
  edge_role_name=$(head -n 1 ${SHARED_DIR}/aws_byo_role_name_edge)
  export edge_role_name
  echo "Patching edge compute pool with iamRole: ${edge_role_name}"
  yq-v4 eval -i '(.compute[] | select(.name == "edge").platform.aws.iamRole) = strenv(edge_role_name)' "${CONFIG}"
fi
