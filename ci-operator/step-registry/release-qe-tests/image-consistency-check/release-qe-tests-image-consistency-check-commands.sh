#!/bin/bash

echo "Running Image Consistency Check"

echo "Payload URL: $MULTISTAGE_PARAM_OVERRIDE_PAYLOAD_URL"
echo "Merge Request ID: $MULTISTAGE_PARAM_OVERRIDE_MERGE_REQUEST_ID"

gitlab_token=$(cat "/var/run/vault/release-tests-token/gitlab_token")
export GITLAB_TOKEN=$gitlab_token

oarctl image-consistency-check --payload-url "$MULTISTAGE_PARAM_OVERRIDE_PAYLOAD_URL" --mr-id "$MULTISTAGE_PARAM_OVERRIDE_MERGE_REQUEST_ID"
