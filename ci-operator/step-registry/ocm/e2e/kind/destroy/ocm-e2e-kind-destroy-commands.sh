#!/bin/bash

KIND_DIR="$SHARED_DIR/kind"
echo "KIND_DIR=$SHARED_DIR/kind"

echo "Contents of $SHARED_DIR"
ls -la "$SHARED_DIR"

echo "Contents of $KIND_DIR"
ls -la "$KIND_DIR"

echo "Changing to $KIND_DIR"
cd "$KIND_DIR" || exit 1

echo "Creating TF plugin directory"
tf_dir=$(mktemp -d -t tf-XXXXX)
echo "TF plugin directory is $tf_dir"

export TF_IN_AUTOMATION=true
export TF_LOG=DEBUG
export TF_INPUT=false
export TF_PLUGIN_CACHE_DIR="$tf_dir"

echo "TF config variables:"
echo "TF_IN_AUTOMATION=$TF_IN_AUTOMATION"
echo "TF_LOG=$TF_LOG"
echo "TF_INPUT=$TF_INPUT"
echo "TF_PLUGIN_CACHE_DIR=$TF_PLUGIN_CACHE_DIR"

echo "Running terraform destroy"
export TF_LOG_PATH="$ARTIFACT_DIR/terraform_destroy.logs"
echo "TF_LOG_PATH=$TF_LOG_PATH"
terraform destroy -auto-approve
