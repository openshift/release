#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cd /go/src/github.com/openshift/hypershift/docs

pip3 install --user -r requirements.txt
~/.local/bin/mkdocs build --strict

echo "Documentation built successfully"

CLOUDFLARE_ACCOUNT_ID=$(cat /var/run/vault/cloudflare-pages/CLOUDFLARE_ACCOUNT_ID)
export CLOUDFLARE_ACCOUNT_ID
CLOUDFLARE_API_TOKEN=$(cat /var/run/vault/cloudflare-pages/CLOUDFLARE_API_TOKEN)
export CLOUDFLARE_API_TOKEN

PROJECT="${CLOUDFLARE_PAGES_PROJECT}"
npm install wrangler

if [[ -n "${PULL_NUMBER:-}" ]]; then
    # Presubmit: deploy to PR preview branch
    BRANCH="pr-${PULL_NUMBER}"
    echo "Deploying to Cloudflare Pages branch: ${BRANCH}"
    npx wrangler pages deploy site \
        --project-name="${PROJECT}" \
        --branch="${BRANCH}" \
        --commit-dirty=true

    PREVIEW_URL="https://${BRANCH}.${PROJECT}.pages.dev"
    echo "${PREVIEW_URL}" > "${SHARED_DIR}/preview-url"
    echo "Preview deployed to: ${PREVIEW_URL}"
else
    # Postsubmit: deploy to production
    echo "Deploying to Cloudflare Pages production"
    npx wrangler pages deploy site \
        --project-name="${PROJECT}" \
        --branch="main"
    echo "Production deployment complete: https://${PROJECT}.pages.dev"
fi
