#!/bin/bash

KIND_DIR="$SHARED_DIR/kind"
PVT_KEY="$KIND_DIR/private.pem"
PUB_KEY="$KIND_DIR/public.pem"
IP_FILE="$KIND_DIR/public_ip"

echo "KIND_DIR=$SHARED_DIR/kind"
echo "PVT_KEY=$KIND_DIR/private.pem"
echo "PUB_KEY=$KIND_DIR/public.pem"
echo "IP_FILE=$KIND_DIR/public_ip"

echo "Creating $KIND_DIR"
mkdir -p "$KIND_DIR"

echo "Changing to $KIND_DIR"
cd "$KIND_DIR" || exit 1

echo "Copying /opt/kind/kind.tf to $KIND_DIR"
cp /opt/kind/kind.tf .

echo "Generating rsa private key in $PVT_KEY"
openssl genrsa -out "$PVT_KEY" 2048
echo "Saving rsa public key in $PUB_KEY"
openssl rsa -pubout -in "$PVT_KEY" -out "$PUB_KEY"
echo "Removing extra lines from $PUB_KEY"
sed -i '/^-----/d' "$PUB_KEY"
echo "Public key:"
cat "$PUB_KEY"
echo

echo "Creating TF plugin directory"
tf_dir=$(mktemp -d -t tf-XXXXX)
echo "TF plugin directory is $tf_dir"

export TF_IN_AUTOMATION=true
export TF_LOG=DEBUG
export TF_INPUT=false
export TF_PLUGIN_CACHE_DIR="$tf_dir"
export TF_VAR_aws_secret="$AWS_KIND_CREDENTIALS"
TF_VAR_public_key=$(cat "$PUB_KEY")
export TF_VAR_public_key

echo "TF config variables:"
echo "TF_IN_AUTOMATION=$TF_IN_AUTOMATION"
echo "TF_LOG=$TF_LOG"
echo "TF_INPUT=$TF_INPUT"
echo "TF_PLUGIN_CACHE_DIR=$TF_PLUGIN_CACHE_DIR"
echo "TF_VAR_aws_secret=$TF_VAR_aws_secret"
echo "TF_VAR_public_key=$TF_VAR_public_key"

echo "Running terraform init"
export TF_LOG_PATH="$ARTIFACT_DIR/terraform_init.logs"
echo "TF_LOG_PATH=$TF_LOG_PATH"
terraform init

echo "Running terraform apply"
export TF_LOG_PATH="$ARTIFACT_DIR/terraform_apply.logs"
echo "TF_LOG_PATH=$TF_LOG_PATH"
terraform apply -auto-approve

echo "Saving public ip to $IP_FILE"
export TF_LOG_PATH="$ARTIFACT_DIR/terraform_output.logs"
echo "TF_LOG_PATH=$TF_LOG_PATH"
terraform output -raw public_ip > "$IP_FILE"

echo "Contents of $IP_FILE"
cat "$IP_FILE"
echo
