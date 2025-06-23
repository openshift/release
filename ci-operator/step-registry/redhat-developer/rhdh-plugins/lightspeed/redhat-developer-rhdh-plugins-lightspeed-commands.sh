#!/bin/bash
GITHUB_TOKEN="$(cat /usr/local/lightspeed-plugin/github-token)"
BUILD_ORG=rhdh-pai-qe
BUILD_REPO=builds
WORKFLOW=plugins.yml

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
  --data '{"event_type": "build_image", "client_payload": { "ref": "main", "workspace": "lightspeed", "tag": "quay.io/rhdh-pai-qe/lightspeed:main" }}' \
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

echo "Building the workspace image"
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