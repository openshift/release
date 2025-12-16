#!/bin/bash

echo "Running Image Consistency Check"

echo "Payload URL: $PAYLOAD_URL"
echo "Merge Request ID: $MERGE_REQUEST_ID"

gitlab_token=$(cat "/var/run/vault/release-tests-token/gitlab_token")
export GITLAB_TOKEN=$gitlab_token

# TODO oarctl image-consistency-check