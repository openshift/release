#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
CONFIG="${SHARED_DIR}/install-config.yaml"


if [[ "${ENABLE_AWS_KMS_KEY_DEFAULT_MACHINE}" == "yes" ]]; then

  key_arn_default_machine=$(head -n 1 ${SHARED_DIR}/aws_kms_key_arn)

  KMS_PATCH_DEFAULT_MACHINE="${ARTIFACT_DIR}/install-config-kms-default-machine.yaml.patch"
  cat > "${KMS_PATCH_DEFAULT_MACHINE}" << EOF
platform:
  aws:
    defaultMachinePlatform:
      rootVolume:
        kmsKeyARN: ${key_arn_default_machine}
EOF
  echo "KMS_PATCH_DEFAULT_MACHINE: ${KMS_PATCH_DEFAULT_MACHINE}"
  cat $KMS_PATCH_DEFAULT_MACHINE
  yq-go m -x -i "${CONFIG}" "${KMS_PATCH_DEFAULT_MACHINE}"
fi


if [[ "${ENABLE_AWS_KMS_KEY_CONTROL_PLANE}" == "yes" ]]; then

  key_arn_control_plane=$(head -n 1 ${SHARED_DIR}/aws_kms_key_arn_control_plane)

  KMS_PATCH_CONTROL_PLANE="${ARTIFACT_DIR}/install-config-kms-control-plane.yaml.patch"
  cat > "${KMS_PATCH_CONTROL_PLANE}" << EOF
controlPlane:
  platform:
    aws:
      rootVolume:
        kmsKeyARN: ${key_arn_control_plane}
EOF
  echo "KMS_PATCH_CONTROL_PLANE: ${KMS_PATCH_CONTROL_PLANE}"
  cat $KMS_PATCH_CONTROL_PLANE
  yq-go m -x -i "${CONFIG}" "${KMS_PATCH_CONTROL_PLANE}"
fi


if [[ "${ENABLE_AWS_KMS_KEY_COMPUTE}" == "yes" ]]; then
  key_arn_compute=$(head -n 1 ${SHARED_DIR}/aws_kms_key_arn_compute)

  KMS_PATCH_COMPUTE="${ARTIFACT_DIR}/install-config-kms-compute.yaml.patch"
  cat > "${KMS_PATCH_COMPUTE}" << EOF
compute:
- platform:
    aws:
      rootVolume:
        kmsKeyARN: ${key_arn_compute}
EOF
  echo "KMS_PATCH_COMPUTE: ${KMS_PATCH_COMPUTE}"
  cat $KMS_PATCH_COMPUTE
  yq-go m -x -i "${CONFIG}" "${KMS_PATCH_COMPUTE}"
fi

echo "defaultMachinePlatform key:"
yq-go r $CONFIG 'platform.aws.defaultMachinePlatform.rootVolume.kmsKeyARN'
echo "controlPlane key:"
yq-go r $CONFIG 'controlPlane.platform.aws.rootVolume.kmsKeyARN'
echo "compute key:"
yq-go r $CONFIG 'compute[0].platform.aws.rootVolume.kmsKeyARN'
