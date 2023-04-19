#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export GITHUB_USER GITHUB_TOKEN GITHUB_ACCOUNTS_ARRAY PREVIOUS_RATE_REMAINING GITHUB_USERNAME_ARRAY GH_RATE_REMAINING CLEAN_REPOS_STATUS CLEAN_WEBHOOK_STATUS DEFAULT_QUAY_ORG DEFAULT_QUAY_ORG_TOKEN

GITHUB_USER=""
GITHUB_TOKEN=""
CLEAN_REPOS_STATUS=0
CLEAN_WEBHOOK_STATUS=0
CLEAN_QUAY_STATUS=0
PREVIOUS_RATE_REMAINING=0
DEFAULT_QUAY_ORG=redhat-appstudio-qe
DEFAULT_QUAY_ORG_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/default-quay-org-token)

# user stored: username:token,username:token
IFS=',' read -r -a GITHUB_ACCOUNTS_ARRAY <<< "$(cat /usr/local/ci-secrets/redhat-appstudio-qe/github_accounts)"
for account in "${GITHUB_ACCOUNTS_ARRAY[@]}"
do :
    IFS=':' read -r -a GITHUB_USERNAME_ARRAY <<< "$account"

    GH_RATE_REMAINING=$(curl -s \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_USERNAME_ARRAY[1]}"\
    https://api.github.com/rate_limit | jq ".rate.remaining")

    echo -e "[INFO ] user: ${GITHUB_USERNAME_ARRAY[0]} with rate limit remaining $GH_RATE_REMAINING"
    if [[ "${GH_RATE_REMAINING}" -ge "${PREVIOUS_RATE_REMAINING}" ]];then
        GITHUB_USER="${GITHUB_USERNAME_ARRAY[0]}"
        GITHUB_TOKEN="${GITHUB_USERNAME_ARRAY[1]}"
    fi
    PREVIOUS_RATE_REMAINING="${GH_RATE_REMAINING}"
done

echo -e "[INFO] Start cleanup with user: ${GITHUB_USER}"

cd "$(mktemp -d)"

git clone --branch main "https://${GITHUB_TOKEN}@github.com/redhat-appstudio/e2e-tests.git" .

make clean-gitops-repositories || CLEAN_REPOS_STATUS=$?
make clean-github-webhooks || CLEAN_WEBHOOK_STATUS=$?
make clean-quay || CLEAN_QUAY_STATUS=$?

if [[ "${CLEAN_REPOS_STATUS}" -ne 0 || "${CLEAN_WEBHOOK_STATUS}" -ne 0 || "${CLEAN_QUAY_STATUS}" -ne 0 ]]; then
    exit 1
fi
