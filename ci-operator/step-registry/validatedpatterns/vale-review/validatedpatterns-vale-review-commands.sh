#!/bin/bash

set -o pipefail

mkdir -p scripts
curl -fsSL https://raw.githubusercontent.com/validatedpatterns/docs/refs/heads/main/utils/vale-pr-comments.sh > scripts/vale-pr-comments.sh
chmod +x scripts/vale-pr-comments.sh

# Disable tracing due to token handling
GITHUB_AUTH_TOKEN=$(cat /tmp/vault/validatedpatterns-vale-github-secret/GITHUB_AUTH_TOKEN)
export GITHUB_AUTH_TOKEN

vale sync

# Allow the comment step to fail without failing the job
./scripts/vale-pr-comments.sh "$PULL_NUMBER" "$PULL_PULL_SHA" || echo "Warning: PR comment posting failed"
