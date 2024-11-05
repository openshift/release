#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "${RELEASE_IMAGE_TARGET},${RELEASE_IMAGE_LATEST}" | tee ${SHARED_DIR}/upgrade-edge
