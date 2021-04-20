#!/bin/bash

KIND_DIR="$SHARED_DIR/kind"
PVT_KEY="$KIND_DIR/private.pem"
PUB_KEY="$KIND_DIR/public.pem"
IP_FILE="$KIND_DIR/public_ip"

mkdir -p "$KIND_DIR"

cd "$KIND_DIR" || exit 1

cp /opt/kind/kind.tf .

openssl genrsa -out "$PVT_KEY" 2048
openssl rsa -pubout -in "$PVT_KEY" -out "$PUB_KEY"
sed -i '/^-----/d' "$PUB_KEY"

export TF_IN_AUTOMATION=true
export TF_LOG=DEBUG
export TF_LOG_PATH="$ARTIFACT_DIR/terraform.logs"
export TF_INPUT=false
export TF_VAR_aws_secret="$AWS_KIND_CREDENTIALS"
TF_VAR_public_key=$(cat "$PUB_KEY")
export TF_VAR_public_key

terraform init
terraform apply -auto-approve
terraform output -raw public_ip > "$IP_FILE"
