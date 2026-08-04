#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

PR_AUTHOR=$(echo ${JOB_SPEC} | jq -r '.refs.pulls[0].author')

if [ "$PR_AUTHOR" == "openshift-cherrypick-robot" ]; then
  echo "openshift-cherrypick-robot PRs don't need a full docs build."
  exit 0
fi

curl https://raw.githubusercontent.com/openshift/openshift-docs/main/scripts/get-updated-preview-urls.sh > scripts/get-updated-preview-urls.sh

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

# Output a list of updated pages
scripts/get-updated-preview-urls.sh ${PULL_NUMBER} > ${SHARED_DIR}/UPDATED_PAGES