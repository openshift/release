#!/bin/bash
set -euo pipefail

# Mints a GitHub App installation token for openshift-app-platform-shift-github-bot.
# Tracing stays disabled for the whole step: the minter logs JWT material.
set +x
export GH_APP_ID=$(cat /var/run/github-app/app-id)
export GH_APP_PEM_FILE_PATH="/var/run/github-app/private-key.pem"
python /app/ghpat_server.py > "${SHARED_DIR}/gh-token"
echo "GitHub App token minted to ${SHARED_DIR}/gh-token."
