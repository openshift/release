#!/bin/bash

echo "Running Image Consistency Check"

echo "Payload URL: $MULTISTAGE_PARAM_OVERRIDE_PAYLOAD_URL"
echo "Merge Request ID: $MULTISTAGE_PARAM_OVERRIDE_MERGE_REQUEST_ID"

# Get the GitLab token from the vault
gitlab_token=$(cat "/var/run/vault/release-tests-token/gitlab_token")
export GITLAB_TOKEN=$gitlab_token

# Get the registry auth file from the vault
registry_auth_file="/var/run/vault/release-tests-registry-conf/art-images"
export REGISTRY_AUTH_FILE=$registry_auth_file

# Get the Current IT Root CAs from the vault
current_it_root_cas="/var/run/vault/release-tests-cert/current_it_root_cas.pem"
export REQUESTS_CA_BUNDLE=$current_it_root_cas

# Run the image consistency check
oarctl image-consistency-check --payload-url "$MULTISTAGE_PARAM_OVERRIDE_PAYLOAD_URL" --mr-id "$MULTISTAGE_PARAM_OVERRIDE_MERGE_REQUEST_ID"
