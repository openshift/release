#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Enabling the IAM service account of minimal permissions for deploying OCP cluster into GCP shared VPC..."

# For now using the same service account as the user-tags testing, 
# but it is possible to use another service account in future. 
cp "${CLUSTER_PROFILE_DIR}/user_tags_sa.json" "${SHARED_DIR}/xpn_min_perm_passthrough.json"
