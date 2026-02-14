#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Build the documentation
cd /go/src/github.com/openshift/hypershift/docs

# Install mkdocs and dependencies
pip3 install --user -r requirements.txt

# Build the documentation with strict mode
~/.local/bin/mkdocs build --strict

echo "Documentation built successfully"

# Deploy to Cloudflare Pages
# Load credentials from vault
CLOUDFLARE_ACCOUNT_ID=$(cat /var/run/vault/cloudflare-pages/CLOUDFLARE_ACCOUNT_ID)
export CLOUDFLARE_ACCOUNT_ID
CLOUDFLARE_API_TOKEN=$(cat /var/run/vault/cloudflare-pages/CLOUDFLARE_API_TOKEN)
export CLOUDFLARE_API_TOKEN

PROJECT="${CLOUDFLARE_PAGES_PROJECT}"
PR_NUMBER="${PULL_NUMBER:-local}"
BRANCH="pr-${PR_NUMBER}"

npm install wrangler

# Deploy to Cloudflare Pages
echo "Deploying to Cloudflare Pages branch: ${BRANCH}"
npx wrangler pages deploy site \
    --project-name="${PROJECT}" \
    --branch="${BRANCH}" \
    --commit-dirty=true

# Save preview URL for next step
PREVIEW_URL="https://${BRANCH}.${PROJECT}.pages.dev"
echo "${PREVIEW_URL}" > "${SHARED_DIR}/preview-url"
echo "Preview deployed to: ${PREVIEW_URL}"
