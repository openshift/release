#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ ! -f ${SHARED_DIR}/security_groups_ids ]]; then
    echo "No custom SG was created, skip now."
    exit 0
fi

CONFIG="${SHARED_DIR}/install-config.yaml"

custom_sg_ids=()

while IFS= read -r line; do
  custom_sg_ids+=("$line")
done < ${SHARED_DIR}/security_groups_ids

echo "The created security groups are:"
echo "${custom_sg_ids[@]}"

sg_json="$(jq --compact-output --null-input '$ARGS.positional' --args -- "${custom_sg_ids[@]}")"

PATCH=$(mktemp)

if [[ "${ENABLE_CUSTOM_SG_DEFAULT_MACHINE}" == "true" ]]; then
  cat >"${PATCH}" <<EOF
platform:
  aws:
    defaultMachinePlatform:
      additionalSecurityGroupIDs: ${sg_json}
EOF
  echo "Patching defaultMachinePlatform:"
  cat $PATCH
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

if [[ "${ENABLE_CUSTOM_SG_CUMPUTE}" == "true" ]]; then
  cat >"${PATCH}" <<EOF
compute:
- platform:
    aws:
      additionalSecurityGroupIDs: ${sg_json}
EOF
  echo "Patching compute node:"
  cat $PATCH
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

if [[ "${ENABLE_CUSTOM_SG_CONTROL_PLANE}" == "true" ]]; then
  cat >"${PATCH}" <<EOF
controlPlane:
  platform:
    aws:
      additionalSecurityGroupIDs: ${sg_json}
EOF
  echo "Patching control plane node:"
  cat $PATCH
  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi
