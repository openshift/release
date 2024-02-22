#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

NETLIFY_AUTH_TOKEN=$(cat /tmp/vault/ocp-docs-netlify-secret/NETLIFY_AUTH_TOKEN)

export NETLIFY_AUTH_TOKEN

echo "Building preview for PR#${PULL_NUMBER}..."

git branch -m latest

IFS=' ' read -r -a DISTROS <<< "${DISTROS}"

for DISTRO in "${DISTROS[@]}"; do
    asciibinder build -d "${DISTRO}"
done

cp scripts/ocpdocs/_previewpage _preview/index.html

cp scripts/ocpdocs/robots_preview.txt _preview/robots.txt

# Deploy docs
netlify deploy --site ${PREVIEW_SITE} --auth ${NETLIFY_AUTH_TOKEN} --alias ${PULL_NUMBER} --dir=_preview

# Output list of updated pages

if [[ "$PREVIEW_COMMENT" == "pages" ]]; then
    scripts/get-updated-preview-urls.sh > ${SHARED_DIR}/UPDATED_PAGES
elif [[ "$PREVIEW_COMMENT" == "site" ]]; then
    touch ${SHARED_DIR}/NETLIFY_SUCCESS
fi