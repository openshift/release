#!/bin/bash

# Switch to the shared directory which is used as the TF work directory
cd "$SHARED_DIR" || exit 1

# Create a temporary plugin cache directory
tf_dir=$(mktemp -d -t tf-XXXXX)
export TF_PLUGIN_CACHE_DIR="$tf_dir"

# TF settings
export TF_IN_AUTOMATION=true
export TF_LOG=DEBUG
export TF_INPUT=false

# Variables needed for destroy
export TF_VAR_aws_secret="$AWS_CREDENTIALS_SECRET"

# Rerun init because plugin cache is not preserved between steps
export TF_LOG_PATH="$ARTIFACT_DIR/terraform_destroy_init.logs"
terraform init

# Destroy resources
export TF_LOG_PATH="$ARTIFACT_DIR/terraform_destroy.logs"
terraform destroy -auto-approve
