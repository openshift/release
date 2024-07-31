#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CONFIG="${SHARED_DIR}/install-config.yaml"

config_byo_iam_profile="${ARTIFACT_DIR}/install-config-byo-iam-profile.yaml.patch"
cat >"${config_byo_iam_profile}" <<EOF
compute:
- platform:
    aws:
      iamProfile: $(head -n 1 ${SHARED_DIR}/aws_byo_profile_name_worker)
controlPlane:
  platform:
    aws:
      iamProfile: $(head -n 1 ${SHARED_DIR}/aws_byo_profile_name_master)
EOF

yq-go m -x -i "${CONFIG}" "${config_byo_iam_profile}"
