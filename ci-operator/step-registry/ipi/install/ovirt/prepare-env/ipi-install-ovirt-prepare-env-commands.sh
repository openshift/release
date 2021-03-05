#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cp "${CLUSTER_PROFILE_DIR}/csi-test-manifest.yaml" "${SHARED_DIR}"
