#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

GITHUB_APP_ID=$(cat "/var/run/vault/capi-versioning-app-credentials/github_app_id")
GITHUB_APP_INSTALLATION_ID=$(cat "/var/run/vault/capi-versioning-app-credentials/github_app_installation_id")
GITHUB_APP_PRIVATE_KEY_PATH="/var/run/vault/capi-versioning-app-credentials/github_app_private_key.pem"

export GITHUB_APP_ID
export GITHUB_APP_INSTALLATION_ID
export GITHUB_APP_PRIVATE_KEY_PATH

if [[ -z "${GITHUB_APP_ID:-}" || -z "${GITHUB_APP_INSTALLATION_ID:-}" || -z "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ]]; then
    echo "ERROR: GitHub App environment variables must be set for version discovery"
    echo "Required: GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY_PATH"
    exit 1
fi

pip install -r hack/versions-management/requirements.txt
make version-discovery DRY_RUN=${DRY_RUN:-false}
