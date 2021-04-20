#!/bin/bash

PVT_KEY="$SHARED_DIR/private.pem"
PUB_KEY="$SHARED_DIR/public.pem"
IP_FILE="$SHARED_DIR/public_ip"

cd "$SHARED_DIR" || exit 1

cp /opt/kind/kind.tf .

openssl genrsa -out "$PVT_KEY" 2048
openssl rsa -pubout -in "$PVT_KEY" -out "$PUB_KEY"
sed -i '/^-----/d' "$PUB_KEY"

tf_dir=$(mktemp -d -t tf-XXXXX)

export TF_IN_AUTOMATION=true
export TF_LOG=DEBUG
export TF_INPUT=false
export TF_PLUGIN_CACHE_DIR="$tf_dir"
export TF_VAR_aws_secret="$AWS_KIND_CREDENTIALS"
TF_VAR_public_key=$(cat "$PUB_KEY")
export TF_VAR_public_key

export TF_LOG_PATH="$ARTIFACT_DIR/terraform_init.logs"
terraform init

export TF_LOG_PATH="$ARTIFACT_DIR/terraform_apply.logs"
terraform apply -auto-approve

export TF_LOG_PATH="$ARTIFACT_DIR/terraform_output.logs"
terraform output -raw public_ip > "$IP_FILE"
