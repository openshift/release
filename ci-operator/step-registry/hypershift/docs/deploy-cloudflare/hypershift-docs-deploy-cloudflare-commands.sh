#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Load credentials from vault
CLOUDFLARE_ACCOUNT_ID=$(cat /var/run/vault/cloudflare-pages/CLOUDFLARE_ACCOUNT_ID)
export CLOUDFLARE_ACCOUNT_ID
CLOUDFLARE_API_TOKEN=$(cat /var/run/vault/cloudflare-pages/CLOUDFLARE_API_TOKEN)
export CLOUDFLARE_API_TOKEN

PROJECT="${CLOUDFLARE_PAGES_PROJECT}"
PR_NUMBER="${PULL_NUMBER:-local}"
BRANCH="pr-${PR_NUMBER}"

# Extract built docs
mkdir -p /tmp/docs-site
tar -xzf "${SHARED_DIR}/docs-site.tar.gz" -C /tmp/docs-site

# Install wrangler
npm install -g wrangler

# Deploy to Cloudflare Pages
echo "Deploying to Cloudflare Pages branch: ${BRANCH}"
wrangler pages deploy /tmp/docs-site \
    --project-name="${PROJECT}" \
    --branch="${BRANCH}" \
    --commit-dirty=true

# Save preview URL for next step
PREVIEW_URL="https://${BRANCH}.${PROJECT}.pages.dev"
echo "${PREVIEW_URL}" > "${SHARED_DIR}/preview-url"
echo "Preview deployed to: ${PREVIEW_URL}"
