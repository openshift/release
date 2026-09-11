#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "${RELEASE_IMAGE_INTERMEDIATE},${RELEASE_IMAGE_TARGET}" | tee ${SHARED_DIR}/upgrade-edge
