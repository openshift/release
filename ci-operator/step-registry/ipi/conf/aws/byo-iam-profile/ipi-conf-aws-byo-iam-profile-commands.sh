#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=$(mktemp)

if [[ "${ENABLE_BYO_IAM_PROFILE_DEFAULT_MACHINE}" == "true" ]]; then
  cat >"${PATCH}" <<EOF
platform:
  aws:
    defaultMachinePlatform:
      iamProfile: $(head -n 1 ${SHARED_DIR}/aws_byo_profile_name_master)
EOF
  echo "Patching defaultMachinePlatform:"
  cat $PATCH
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

if [[ "${ENABLE_BYO_IAM_PROFILE_CUMPUTE}" == "true" ]]; then
  cat >"${PATCH}" <<EOF
compute:
- platform:
    aws:
      iamProfile: $(head -n 1 ${SHARED_DIR}/aws_byo_profile_name_worker)
EOF
  echo "Patching compute node:"
  cat $PATCH
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

if [[ "${ENABLE_BYO_IAM_PROFILE_CONTROL_PLANE}" == "true" ]]; then
  cat >"${PATCH}" <<EOF
controlPlane:
  platform:
    aws:
      iamProfile: $(head -n 1 ${SHARED_DIR}/aws_byo_profile_name_master)
EOF
  echo "Patching control plane node:"
  cat $PATCH
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

# The edge compute pool is a named entry (compute[name=edge]), so it cannot be
# targeted by the index-based merge above; select it by name with yq-v4 instead.
if [[ "${ENABLE_BYO_IAM_PROFILE_EDGE}" == "true" ]]; then
  edge_profile_name=$(head -n 1 ${SHARED_DIR}/aws_byo_profile_name_edge)
  export edge_profile_name
  echo "Patching edge compute pool with iamProfile: ${edge_profile_name}"
  yq-v4 eval -i '(.compute[] | select(.name == "edge").platform.aws.iamProfile) = strenv(edge_profile_name)' "${CONFIG}"
fi
