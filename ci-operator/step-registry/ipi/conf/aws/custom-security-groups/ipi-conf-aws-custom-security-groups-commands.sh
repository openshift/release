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

config_custom_security_groups="${ARTIFACT_DIR}/install-config-custom-security-groups.yaml.patch"
cat > "${config_custom_security_groups}" << EOF
compute:
- platform:
    aws:
      additionalSecurityGroupIDs: ${sg_json}
controlPlane:
  platform:
    aws:
      additionalSecurityGroupIDs: ${sg_json}
EOF

yq-go m -x -i "${CONFIG}" "${config_custom_security_groups}"
