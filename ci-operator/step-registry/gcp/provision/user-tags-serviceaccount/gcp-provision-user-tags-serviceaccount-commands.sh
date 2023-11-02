#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Enabling the IAM service-account for userTags testing on GCP..."
cp "${CLUSTER_PROFILE_DIR}/user_tags_sa.json" "${SHARED_DIR}/"
