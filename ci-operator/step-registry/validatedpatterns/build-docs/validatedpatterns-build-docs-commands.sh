#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

NETLIFY_AUTH_TOKEN=$(cat /tmp/vault/validatedpatterns-docs-netlify/NETLIFY_AUTH_TOKEN_VP)

export NETLIFY_AUTH_TOKEN

echo "Building preview for PR#${PULL_NUMBER}..."

hugo --minify

echo "User-agent: *" > public/robots.txt
echo "Disallow: /" >> public/robots.txt

# Create zip file of public dir
echo "Creating zip file of public dir..."
cd public
zip -r ../site.zip .
cd ..

# Deploy using Netlify API as draft preview with custom alias
echo "Deploying draft preview to Netlify using API..."
DEPLOY_RESPONSE=$(curl -s -X POST \
  "https://api.netlify.com/api/v1/sites/${PREVIEW_SITE}/deploys?draft=true&branch=${PULL_NUMBER}" \
  -H "Authorization: Bearer ${NETLIFY_AUTH_TOKEN}" \
  -H "Content-Type: application/zip" \
  --data-binary @site.zip)

# Extract deploy ID and URL from response
DEPLOY_ID=$(echo "$DEPLOY_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
DEPLOY_URL=$(echo "$DEPLOY_RESPONSE" | grep -o '"deploy_url":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$DEPLOY_ID" ]; then
  echo "Failed to deploy. Response: $DEPLOY_RESPONSE"
  exit 1
fi

echo "Deploy ID: $DEPLOY_ID"
echo "Draft deployment completed successfully!"
echo "Preview URL: $DEPLOY_URL"

# Clean up zip file
rm -f site.zip
