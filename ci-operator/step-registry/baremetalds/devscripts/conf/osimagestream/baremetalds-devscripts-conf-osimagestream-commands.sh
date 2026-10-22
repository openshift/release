#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf os image stream command ************"

if [[ -n "${OS_IMAGE_STREAM:-}" ]]; then
  echo "export OS_IMAGE_STREAM=${OS_IMAGE_STREAM}" >> "${SHARED_DIR}/dev-scripts-additional-config"
fi
