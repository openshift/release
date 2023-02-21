#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=$PATH:/tmp/bin
mkdir -p /tmp/bin

export GITHUB_USER GITHUB_TOKEN GITHUB_ACCOUNTS_ARRAY PREVIOUS_RATE_REMAINING GITHUB_USERNAME_ARRAY GH_RATE_REMAINING CLEAN_REPOS_STATUS CLEAN_WEBHOOK_STATUS

GITHUB_USER=""
GITHUB_TOKEN=""
OPENSHIFT_USERNAME="kubeadmin"
PREVIOUS_RATE_REMAINING=0

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

echo -e "[INFO] Start tests with user: ${GITHUB_USER}"

cd "$(mktemp -d)"

git clone --branch main "https://${GITHUB_TOKEN}@github.com/redhat-appstudio/e2e-tests.git" .

make clean-gitops-repositories || CLEAN_REPOS_STATUS=$?
make clean-github-webhooks || CLEAN_WEBHOOK_STATUS=$?

if [[ "${CLEAN_REPOS_STATUS}" -ne 0 ]];then
    echo -e "[ERROR]: Failed to clean gitops repositories"
    exit "${CLEAN_REPOS_STATUS}"
fi

if [[ "${CLEAN_WEBHOOK_STATUS}" -ne 0 ]];then
    echo -e "[ERROR]: Failed to clean webhooks"
    exit "${CLEAN_WEBHOOK_STATUS}"
fi
