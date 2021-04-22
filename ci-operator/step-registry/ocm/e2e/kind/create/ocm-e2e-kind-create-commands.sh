#!/bin/bash

# File paths
PVT_KEY="$SHARED_DIR/private.pem"
PUB_KEY="$SHARED_DIR/public.pem"
IP_FILE="$SHARED_DIR/public_ip"

# Switch to the shared directory which is used as the TF work directory
cd "$SHARED_DIR" || exit 1

# Copy TF files to shared directory
cp /opt/kind/*.tf .

# Create an RSA key pair
openssl genrsa -out "$PVT_KEY" 2048
openssl rsa -pubout -in "$PVT_KEY" -out "$PUB_KEY"
# Reformat public key file for AWS import
sed -i '/^-----/d' "$PUB_KEY"

# Create a temporary plugin cache directory
tf_dir=$(mktemp -d -t tf-XXXXX)
export TF_PLUGIN_CACHE_DIR="$tf_dir"

# TF settings
export TF_IN_AUTOMATION=true
export TF_LOG=DEBUG
export TF_INPUT=false

# Variables needed for create
export TF_VAR_aws_secret="$AWS_CREDENTIALS_SECRET"
export TF_VAR_aws_instance_type="$AWS_INSTANCE_TYPE"
export TF_VAR_aws_region="$AWS_REGION"

# Set public key. Split definition needed to pass shellcheck
TF_VAR_public_key=$(cat "$PUB_KEY")
export TF_VAR_public_key

# Initialize TF. This will have to be done for each Prow step because
# the plugin cache directory will not be persisted between steps.
export TF_LOG_PATH="$ARTIFACT_DIR/terraform_create_init.logs"
terraform init

# Create resources
export TF_LOG_PATH="$ARTIFACT_DIR/terraform_apply.logs"
terraform apply -auto-approve

# Save VM IP address
export TF_LOG_PATH="$ARTIFACT_DIR/terraform_create_output.logs"
terraform output -raw public_ip > "$IP_FILE"

# Wait for VM to be ready
KEY="$SHARED_DIR/private.pem"
IP="$(cat "$SHARED_DIR/public_ip")"
HOST="ec2-user@$IP"
OPT=(-o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" -i "$KEY" "$HOST")
echo "VM is $HOST"
echo "Waiting up to 5 minutes for VM to be ready"
_timeout=300
_elapsed=''
_step=15
while true; do
    # Check if this is the first iteration
    if [[ -z "$_elapsed" ]]; then
        # It is, so set elapsed to 0
        _elapsed=0
    else
        # It isn't, so sleep and update _elapsed
        sleep $_step
        _elapsed=$(( _elapsed + _step ))
    fi
    # Try to connect
    echo "Trying to connect to VM..."
    if ssh "${OPT[@]}" hostname ; then
        # Successfully connected
        echo "VM ready after ${_elapsed}s"
        break
    else
        # Failed to connect
        echo "Could not connect to $IP"
    fi
    # Check elapsed time againe
    if (( _elapsed > _timeout )); then
        # Timeout has passed, so exit with error
        echo "Timeout (${_timeout}s) waiting for VM to be ready"
        exit 1
    fi
    echo "VM not ready yet. Will retry (${_elapsed}/${_timeout}s)"
done
