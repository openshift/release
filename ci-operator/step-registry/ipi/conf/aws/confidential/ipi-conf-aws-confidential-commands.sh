#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

if [[ -n "${COMPUTE_CONFIDENTIAL_COMPUTE}" ]]; then
  yq-v4 eval -i '.compute[0].platform.aws.cpuOptions.confidentialCompute = env(COMPUTE_CONFIDENTIAL_COMPUTE)' "${CONFIG}"
  if [[ -n "${CONFIDENTIAL_COMPUTE_AMI}" ]]; then
    yq-v4 eval -i '.compute[0].platform.aws.amiID = env(CONFIDENTIAL_COMPUTE_AMI)' "${CONFIG}"
  fi
fi

if [[ -n "${CONTROL_PLANE_CONFIDENTIAL_COMPUTE}" ]]; then
  yq-v4 eval -i '.controlPlane.platform.aws.cpuOptions.confidentialCompute = env(CONTROL_PLANE_CONFIDENTIAL_COMPUTE)' "${CONFIG}"
  if [[ -n "${CONFIDENTIAL_COMPUTE_AMI}" ]]; then
    yq-v4 eval -i '.controlPlane.platform.aws.amiID = env(CONFIDENTIAL_COMPUTE_AMI)' "${CONFIG}"
  fi
fi

if [[ -n "${CONFIDENTIAL_COMPUTE}" ]]; then
  yq-v4 eval -i '.platform.aws.defaultMachinePlatform.cpuOptions.confidentialCompute = env(CONFIDENTIAL_COMPUTE)' "${CONFIG}"
  if [[ -n "${CONFIDENTIAL_COMPUTE_AMI}" ]]; then
    yq-v4 eval -i '.platform.aws.defaultMachinePlatform.amiID = env(CONFIDENTIAL_COMPUTE_AMI)' "${CONFIG}"
  fi
fi

echo "install-config:"
yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform})' "${CONFIG}"