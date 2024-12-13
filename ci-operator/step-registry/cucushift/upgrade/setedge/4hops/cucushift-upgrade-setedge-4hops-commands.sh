#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "${RELEASE_IMAGE_INTERMEDIATE1},${RELEASE_IMAGE_INTERMEDIATE2},${RELEASE_IMAGE_INTERMEDIATE3},${RELEASE_IMAGE_TARGET}" | tee ${SHARED_DIR}/upgrade-edge
