#!/bin/bash

cd "$SHARED_DIR" || exit 1

tf_dir=$(mktemp -d -t tf-XXXXX)

export TF_IN_AUTOMATION=true
export TF_LOG=DEBUG
export TF_INPUT=false
export TF_PLUGIN_CACHE_DIR="$tf_dir"
export TF_VAR_aws_secret="$AWS_KIND_CREDENTIALS"
export TF_VAR_public_key=""

export TF_LOG_PATH="$ARTIFACT_DIR/terraform_destroy.logs"
terraform destroy -auto-approve
