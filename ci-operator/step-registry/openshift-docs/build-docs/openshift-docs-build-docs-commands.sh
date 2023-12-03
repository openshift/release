#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

NETLIFY_AUTH_TOKEN=$(cat /tmp/vault/ocp-docs-netlify-secret/NETLIFY_AUTH_TOKEN)

export NETLIFY_AUTH_TOKEN

echo "Building preview for PR#${PULL_NUMBER}..."

git branch -m latest

asciibinder build -d ${DISTRO}

cp scripts/ocpdocs/_previewpage _preview/index.html

cp scripts/ocpdocs/robots_preview.txt _preview/robots.txt

# Touch ${SHARED_DIR}/NETLIFY_SUCCESS if the build succeeds
netlify deploy --site ${PREVIEW_SITE} --auth ${NETLIFY_AUTH_TOKEN} --alias ${PULL_NUMBER} --dir=_preview && touch ${SHARED_DIR}/NETLIFY_SUCCESS
