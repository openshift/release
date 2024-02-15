#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

export ACS__API_TOKEN ACS__CENTRAL_ENDPOINT DEVELOPER_HUB__CATALOG__URL GITHUB__APP__APP_ID GITHUB__APP__CLIENT_ID GITHUB__APP__CLIENT_SECRET GITHUB__APP__WEBHOOK_SECRET GITHUB__APP__WEBHOOK_URL GITHUB__APP__PRIVATE_KEY IMAGE_REPOSITORY DOCKER_USERNAME DOCKER_PASSWORD
ACS__API_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-api-token)
ACS__CENTRAL_ENDPOINT=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-central-endpoint)
DEVELOPER_HUB__CATALOG__URL=https://github.com/redhat-appstudio/tssc-sample-templates/blob/main/all.yaml
GITHUB__APP__APP_ID=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-app-id)
GITHUB__APP__CLIENT_ID=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-client-id)
GITHUB__APP__CLIENT_SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-client-secret)
GITHUB__APP__WEBHOOK_SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-webhook-secret)
GITHUB__APP__WEBHOOK_URL=GITHUB_APP_WEBHOOK_URL
GITHUB__APP__PRIVATE_KEY=$(base64 -d < /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-private-key)
IMAGE_REPOSITORY=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-default-image-repository)
DOCKER_USERNAME=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-robot-username)
DOCKER_PASSWORD=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-robot-password)

# git clone to rhtap-installer
git clone "https://github.com/redhat-appstudio/rhtap-installer.git" cloned
cd cloned

echo "[INFO]Generate private-values.yaml file ..."
./bin/make.sh values

echo "[INFO]Install RHTAP ..."
./bin/make.sh apply -n rhtap -- --values private-values.yaml
