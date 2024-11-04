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
