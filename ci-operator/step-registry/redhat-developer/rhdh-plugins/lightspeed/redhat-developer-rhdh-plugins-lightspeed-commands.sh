#!/bin/bash
GITHUB_TOKEN="$(cat /usr/local/lightspeed-plugin/github-token)"
BUILD_ORG=rhdh-pai-qe
BUILD_REPO=builds
WORKFLOW=plugins.yml

export LIGHTSPEED_IMAGE_TAG=quay.io/rhdh-pai-qe/lightspeed:main

previous_workflow_id=$(curl -sS -X GET "https://api.github.com/repos/$BUILD_ORG/$BUILD_REPO/actions/workflows/$WORKFLOW/runs" \
  -H 'Accept: application/vnd.github.antiope-preview+json' \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "Authorization: Bearer $GITHUB_TOKEN" | jq 'first(.workflow_runs[]) | .id')
last_workflow_id=$previous_workflow_id

# Trigger an image build using GH actions
curl -H "Accept: application/vnd.github.everest-preview+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "Authorization: token $GITHUB_TOKEN" \
  --request POST \
  --data '{"event_type": "build_image", "client_payload": { "ref": "main", "workspace": "lightspeed", "tag": "'"$LIGHTSPEED_IMAGE_TAG"'" }}' \
  https://api.github.com/repos/$BUILD_ORG/$BUILD_REPO/dispatches

# Wait for new run to appear
while [[ $previous_workflow_id == "$last_workflow_id" ]]
do
  sleep 1s
  last_workflow=$(curl -sS -X GET "https://api.github.com/repos/$BUILD_ORG/$BUILD_REPO/actions/workflows/$WORKFLOW/runs" \
    -H 'Accept: application/vnd.github.antiope-preview+json' \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Authorization: Bearer $GITHUB_TOKEN" | jq 'first(.workflow_runs[])')

  last_workflow_id=$(echo $last_workflow | jq '.id')
  conclusion=$(echo $last_workflow | jq '.conclusion')
  status=$(echo $last_workflow | jq '.status')
  job_url=$(echo $last_workflow | jq '.html_url')
done

echo "Building the dynamic plugin image"
echo $job_url

# Wait for the run to finish
while [[ $conclusion == "null" && $status != "\"completed\"" ]]
do
  sleep 10s

  workflow=$(curl -sS -X GET "https://api.github.com/repos/$BUILD_ORG/$BUILD_REPO/actions/runs/$last_workflow_id" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28")
    
  conclusion=$(echo $workflow | jq '.conclusion')
  status=$(echo $workflow | jq '.status')
done

echo "Image build finished with: $conclusion"
if [[ $conclusion != "\"success\"" ]]
then
  exit 1
fi

# Deploy RHDH to test cluster
git clone https://github.com/rhdh-pai-qe/rhdh-deployment
cd rhdh-deployment || exit 1

cat >./base/private.env <<EOF
GITHUB__APP__ID=$(cat /usr/local/lightspeed-plugin/github-app-id)
GITHUB__APP__CLIENT__ID=$(cat /usr/local/lightspeed-plugin/github-app-client-id)
GITHUB__APP__CLIENT__SECRET=$(cat /usr/local/lightspeed-plugin/github-app-client-secret)
GITHUB__APP__PRIVATE_KEY=PLACEHOLDER
GITHUB__APP__WEBHOOK__URL=URL
GITHUB__APP__WEBHOOK__SECRET=SECRET
GITHUB__HOST=github.com
GITHUB__ORG__NAME=rhdh-pai-qe
LIGHTSPEED_URL=$(cat /usr/local/lightspeed-plugin/lightspeed-url)
LIGHTSPEED_API_KEY=$(cat /usr/local/lightspeed-plugin/lightspeed-api-key)
KEYCLOAK_CLIENT_ID=$(cat /usr/local/lightspeed-plugin/keycloak-client-id)
KEYCLOAK_CLIENT_SECRET=$(cat /usr/local/lightspeed-plugin/keycloak-client-secret)
KEYCLOAK_METADATA_URL=$(cat /usr/local/lightspeed-plugin/keycloak-metadata-url)
KEYCLOAK_BASE_URL=$(cat /usr/local/lightspeed-plugin/keycloak-base-url)
KEYCLOAK_REALM=$(cat /usr/local/lightspeed-plugin/keycloak-realm)
BACKEND_SECRET=$(cat /usr/local/lightspeed-plugin/backend-secret)
EOF

cat /usr/local/lightspeed-plugin/github-app-private-key > key.pem

oc login --token="$(cat /usr/local/lightspeed-plugin/oc-login-token)" --server="$(cat /usr/local/lightspeed-plugin/oc-login-server)" --insecure-skip-tls-verify

echo "Deploying RHDH"

export RHDH_NAMESPACE=rhdh-test-main
bash apply.sh --keycloak