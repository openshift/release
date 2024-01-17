#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export GITHUB_USER GITHUB_TOKEN GITHUB_ACCOUNTS_ARRAY PREVIOUS_RATE_REMAINING GITHUB_USERNAME_ARRAY GH_RATE_REMAINING CLEAN_REPOS_STATUS CLEAN_WEBHOOK_STATUS DEFAULT_QUAY_ORG DEFAULT_QUAY_ORG_TOKEN QE_SPRAYPROXY_HOST QE_SPRAYPROXY_TOKEN

GITHUB_USER=""
GITHUB_TOKEN=""
CLEAN_REPOS_STATUS=0
CLEAN_WEBHOOK_STATUS=0
CLEAN_QUAY_REPOS_AND_ROBOTS_STATUS=0
CLEAN_QUAY_TAGS_STATUS=0
CLEAN_PRIVATE_REPO_STATUS=0
CLEAN_REGISTERED_SERVERS_STATUS=0
PREVIOUS_RATE_REMAINING=0
DEFAULT_QUAY_ORG=redhat-appstudio-qe
DEFAULT_QUAY_ORG_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/default-quay-org-token)
QE_SPRAYPROXY_HOST=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/qe-sprayproxy-host)
QE_SPRAYPROXY_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/qe-sprayproxy-token)

# user stored: username:token,username:token
IFS=',' read -r -a GITHUB_ACCOUNTS_ARRAY <<<"$(cat /usr/local/ci-secrets/redhat-appstudio-qe/github_accounts)"
for account in "${GITHUB_ACCOUNTS_ARRAY[@]}"; do
    :
    IFS=':' read -r -a GITHUB_USERNAME_ARRAY <<<"$account"

    GH_RATE_REMAINING=$(curl -s \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_USERNAME_ARRAY[1]}" \
        https://api.github.com/rate_limit | jq ".rate.remaining")

    echo -e "[INFO ] user: ${GITHUB_USERNAME_ARRAY[0]} with rate limit remaining $GH_RATE_REMAINING"
    if [[ "${GH_RATE_REMAINING}" -ge "${PREVIOUS_RATE_REMAINING}" ]]; then
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
make clean-quay-repos-and-robots || CLEAN_QUAY_REPOS_AND_ROBOTS_STATUS=$?
make clean-quay-tags || CLEAN_QUAY_TAGS_STATUS=$?
make clean-private-repos || CLEAN_PRIVATE_REPO_STATUS=$?
make clean-registered-servers || CLEAN_REGISTERED_SERVERS_STATUS=$?


if [[ "${CLEAN_REPOS_STATUS}" -ne 0 || "${CLEAN_WEBHOOK_STATUS}" -ne 0 || "${CLEAN_QUAY_REPOS_AND_ROBOTS_STATUS}" -ne 0 || "${CLEAN_QUAY_TAGS_STATUS}" -ne 0 || "${CLEAN_PRIVATE_REPO_STATUS}" -ne 0 || "${CLEAN_REGISTERED_SERVERS_STATUS}" -ne 0 ]]; then
    exit 1
fi
