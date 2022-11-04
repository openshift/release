#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=$PATH:/tmp/bin
mkdir -p /tmp/bin

export GITHUB_USER GITHUB_TOKEN QUAY_TOKEN QUAY_OAUTH_USER QUAY_OAUTH_TOKEN QUAY_OAUTH_TOKEN_RELEASE_SOURCE QUAY_OAUTH_TOKEN_RELEASE_DESTINATION OFFLINE_TOKEN KCP_KUBECONFIG_SECRET REPO_NAME

GITHUB_USER=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/github-user)
GITHUB_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/github-token)
QUAY_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/quay-token)
QUAY_OAUTH_USER=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/quay-oauth-user)
QUAY_OAUTH_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/quay-oauth-token)
QUAY_OAUTH_TOKEN_RELEASE_SOURCE=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/quay-oauth-token-release-source)
QUAY_OAUTH_TOKEN_RELEASE_DESTINATION=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/quay-oauth-token-release-destination)
OFFLINE_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/offline_sso_token)
KCP_KUBECONFIG_SECRET="/usr/local/ci-secrets/redhat-appstudio-qe/kcp_kubeconfig"

mkdir -p $HOME/.configs

# Cannot read a kubeconfig from /usr/local/***
cp "/usr/local/ci-secrets/redhat-appstudio-qe/kcp_kubeconfig" $HOME/.configs && chmod -R 755 $HOME/.configs

git config --global user.name "redhat-appstudio-qe-bot"
git config --global user.email redhat-appstudio-qe-bot@redhat.com

mkdir -p "${HOME}/creds"
GIT_CREDS_PATH="${HOME}/creds/file"
git config --global credential.helper "store --file ${GIT_CREDS_PATH}"
echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com" > "${GIT_CREDS_PATH}"

# Puting infra-deployments repo by default. All periodic jobs are running there.
REPO_NAME=${REPO_NAME:-"infra-deployments"}

cd "$(mktemp -d)"
git clone --branch main "https://${GITHUB_TOKEN}@github.com/redhat-appstudio/e2e-tests.git" .
make ci/prepare/e2e-branch
/bin/bash ./scripts/install-appstudio-kcp.sh -kc kcp-stable-root -kk "$HOME/.configs/kcp_kubeconfig" -ck $KUBECONFIG -s --e2e
