#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

./test/aro-hcp-tests slot-manager acquire --deploy-env "${ARO_HCP_DEPLOY_ENV}" --shared-dir "${SHARED_DIR}"
