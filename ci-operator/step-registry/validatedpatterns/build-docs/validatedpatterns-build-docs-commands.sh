#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

NETLIFY_AUTH_TOKEN=$(cat /tmp/vault/validatedpatterns-netlify-secret/NETLIFY_AUTH_TOKEN)

export NETLIFY_AUTH_TOKEN

echo "Building preview for PR#${PULL_NUMBER}..."

git branch -m latest

hugo --minify

echo "User-agent: *" > public/robots.txt
echo "Disallow: /" >> public/robots.txt

# Deploy docs
netlify deploy --site ${PREVIEW_SITE} --auth ${NETLIFY_AUTH_TOKEN} --alias ${PULL_NUMBER} --dir=public
