#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
CONFIG="${SHARED_DIR}/install-config.yaml"

patch=$(mktemp)

if [[ "${ENABLE_AWS_AMI_DEFAULT_MACHINE}" == "yes" ]]; then

  ami_id=$(< "${SHARED_DIR}/aws_ami")
  cat > "${patch}" << EOF
platform:
  aws:
    defaultMachinePlatform:
      amiID: ${ami_id}
EOF
  echo "ENABLE_AWS_AMI_DEFAULT_MACHINE:"
  cat $patch
  yq-go m -x -i "${CONFIG}" "${patch}"
fi

if [[ "${ENABLE_AWS_AMI_CONTROL_PLANE}" == "yes" ]]; then
  
  ami_id=$(< "${SHARED_DIR}/aws_ami_control_plane")
  cat > "${patch}" << EOF
controlPlane:
  platform:
    aws:
      amiID: ${ami_id}
EOF
  echo "ENABLE_AWS_AMI_CONTROL_PLANE:"
  cat $patch
  yq-go m -x -i "${CONFIG}" "${patch}"
fi


if [[ "${ENABLE_AWS_AMI_COMPUTE}" == "yes" ]]; then

  ami_id=$(< "${SHARED_DIR}/aws_ami_compute")
  cat > "${patch}" << EOF
compute:
- platform:
    aws:
      amiID: ${ami_id}
EOF
  echo "ENABLE_AWS_AMI_COMPUTE:"
  cat $patch
  yq-go m -x -i "${CONFIG}" "${patch}"
fi

echo "defaultMachinePlatform AMI:"
yq-go r $CONFIG 'platform.aws.defaultMachinePlatform.amiID'
echo "controlPlane AMI:"
yq-go r $CONFIG 'controlPlane.platform.aws.amiID'
echo "compute AMI:"
yq-go r $CONFIG 'compute[0].platform.aws.amiID'
