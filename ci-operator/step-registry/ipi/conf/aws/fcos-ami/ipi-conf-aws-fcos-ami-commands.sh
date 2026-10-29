#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

URL="https://builds.coreos.fedoraproject.org/streams/${STREAM}.json"
FCOS_AMI="$(curl -s "${URL}" | jq ".architectures.\"${ARCHITECTURE}\".images.aws.regions.\"${LEASED_RESOURCE}\".image")"

CONFIG_PATCH_AMI="${SHARED_DIR}/install-config-ami.yaml.patch"
cat >> "${CONFIG_PATCH_AMI}" << EOF
platform:
  aws:
    amiID: ${FCOS_AMI}
EOF
yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH_AMI}"
cp "${SHARED_DIR}/install-config-ami.yaml.patch" "${ARTIFACT_DIR}/"
