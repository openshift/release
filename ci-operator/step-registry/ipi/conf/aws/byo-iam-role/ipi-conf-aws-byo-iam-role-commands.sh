#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CONFIG="${SHARED_DIR}/install-config.yaml"

config_byo_iam_role="${ARTIFACT_DIR}/install-config-byo-iam-role.yaml.patch"
cat > "${config_byo_iam_role}" << EOF
compute:
- platform:
    aws:
      iamRole: $(head -n 1 ${SHARED_DIR}/aws_byo_role_name_worker)
controlPlane:
  platform:
    aws:
      iamRole: $(head -n 1 ${SHARED_DIR}/aws_byo_role_name_master)
EOF

yq-go m -x -i "${CONFIG}" "${config_byo_iam_role}"
